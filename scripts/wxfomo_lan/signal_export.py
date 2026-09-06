"""Read-only completed briefing export. No provider calls or production writes."""
import datetime
import hashlib
import json
import math
import os
import sqlite3
import urllib.parse
from contextlib import closing

from .briefing import BriefingError, references, result_projection, validate_briefing
from .cross_ca import address_mentions, cross_ca_cards
from .messages import MessageRepository, MessageSourceUnavailable
from .minimax import _address_evidence
from .signal_contract import SyncError, encode_payload, require


def _json(value):
    def unique(pairs):
        result = {}
        for key, child in pairs:
            require(key not in result, 'source_invalid')
            result[key] = child
        return result
    return json.loads(value, object_pairs_hook=unique,
                      parse_constant=lambda unused: (_ for _ in ()).throw(ValueError()))


def _ids(row):
    ids = _json(row['source_event_ids_json'])
    require(type(ids) is list and all(type(item) is str and item for item in ids), 'source_invalid')
    require(len(ids) == len(set(ids)), 'source_invalid')
    return ids


def _epoch(value):
    if type(value) in (int, float):
        return float(value) if math.isfinite(value) else None
    if type(value) is str:
        try:
            parsed = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
            return parsed.timestamp() if parsed.tzinfo is not None else None
        except (ValueError, OverflowError):
            return None
    return None


def _iso(value):
    return datetime.datetime.fromtimestamp(value, datetime.timezone.utc).isoformat().replace('+00:00', 'Z')


def completed_after(analysis_path, after_id, limit=10):
    require(type(after_id) is int and after_id >= 0 and type(limit) is int and 1 <= limit <= 10, 'cursor_invalid')
    failure = False
    try:
        uri = 'file:{}?mode=ro'.format(urllib.parse.quote(os.path.abspath(analysis_path)))
        with closing(sqlite3.connect(uri, uri=True, timeout=0.25)) as connection:
            connection.row_factory = sqlite3.Row
            connection.execute('PRAGMA query_only=ON')
            rows = connection.execute('''
                SELECT r.analysis_id,r.job_id,r.result_json,r.model,r.created_at,
                       j.cadence,j.window_start,j.window_end,j.source_event_ids_json
                FROM analysis_results r JOIN analysis_jobs j ON j.job_id=r.job_id
                WHERE j.state='succeeded' AND r.analysis_id>? ORDER BY r.analysis_id LIMIT ?
            ''', (after_id, limit)).fetchall()
            return [dict(row) for row in rows]
    except (sqlite3.Error, OSError, ValueError, TypeError):
        failure = True
    if failure:
        raise SyncError('source_unavailable')


def _remap(value, mapping):
    if type(value) is list:
        return [_remap(item, mapping) for item in value]
    if type(value) is dict:
        return {key: ([mapping[item] for item in child] if key == 'source_message_ids'
                      else _remap(child, mapping)) for key, child in value.items()}
    return value


def _build(row, source_messages, device_id, store_id):
    ids = _ids(row)
    mapping = {key: 'M{:04d}'.format(index) for index, key in enumerate(ids, 1)}
    raw_result = _json(row['result_json'])
    briefing = validate_briefing(raw_result['briefing'], set(ids))
    supplied = list(source_messages.values()) if type(source_messages) is dict else source_messages
    require(type(supplied) is list, 'source_invalid')
    by_id = {}
    for message in supplied:
        require(type(message) is dict, 'source_invalid')
        event_id = message.get('eventId')
        if event_id in mapping:
            require(event_id not in by_id, 'source_invalid')
            require(type(message.get('content')) is str, 'source_invalid')
            by_id[event_id] = message
    messages = []
    for event_id in ids:
        if event_id in by_id:
            item = by_id[event_id]
            messages.append(dict(eventId=event_id, content=item['content'],
                                 group=item.get('group') or item.get('groupName') or '未知群',
                                 sender=item.get('sender') or item.get('senderDisplayName') or '',
                                 observedAt=item.get('observedAt')))
    evidence = _address_evidence([dict(item, observedAt=_epoch(item['observedAt']) or 0.0) for item in messages])
    # Missing records remain explicit gaps; readable sources must still support
    # every exported CA spelling. Never manufacture evidence for a missing row.
    for project in briefing['projects']:
        for address in project['addresses']:
            cited = set(address['source_message_ids'])
            raw = address['address']
            key = raw.lower() if raw.lower().startswith('0x') else raw
            direct = evidence.get(key, {}).get('verbatim_sources', {}).get(raw, [])
            if cited <= set(by_id):
                require(bool(cited.intersection(direct)), 'invalid_address_reference')
    projection = result_projection(briefing)
    # Frozen aliases retain their own report citations and readability counts.
    # CA counts use one canonical event, represented by its first frozen ID.
    canonical_ids, ca_ids, ca_messages = {}, {}, []
    for message in messages:
        event_id = message['eventId']
        canonical_id = by_id[event_id].get('canonicalEventId', event_id)
        require(type(canonical_id) is str and bool(canonical_id), 'source_invalid')
        representative = canonical_ids.setdefault(canonical_id, event_id)
        ca_ids[event_id] = representative
        if representative == event_id:
            ca_messages.append(message)
    ca_summaries = [dict(item, sourceMessageIDs=list(dict.fromkeys(
        ca_ids.get(event_id, event_id) for event_id in item['sourceMessageIDs'])))
        for item in projection['cryptoAddresses']]
    cards = cross_ca_cards(ca_messages, ca_summaries)
    spellings = {}
    for message in ca_messages:
        for mention in address_mentions(message['content']):
            key = (mention['network'], mention['normalizedAddress'],
                   message['group'] if mention['network'] == 'unknown' else '')
            spellings.setdefault(key, mention['address'])
    exported = []
    for card in cards['items']:
        key = (card['network'], card['address'], card['groupNames'][0] if card['network'] == 'unknown' else '')
        require(key in spellings, 'invalid_address_reference')
        exported.append(dict(address=spellings[key], network=card['network'], groups=card['groupNames'],
                             mentionCount=card['mentionCount'], uniqueStatementCount=card['uniqueStatementCount'],
                             duplicateCount=card['duplicateCount'], summary=card['summary'],
                             sourceMessageIDs=[mapping[item] for item in card['sourceMessageIDs']]))
    times = [_epoch(message['observedAt']) for message in messages]
    known_times = [value for value in times if value is not None]
    complete = len(messages) == len(ids)
    report = dict(id='wecom:{}:{}:{}'.format(device_id, store_id, hashlib.sha256(row['job_id'].encode('utf-8')).hexdigest()),
                  revision=row['analysis_id'], cadence=row['cadence'], windowStart=_iso(row['window_start']),
                  windowEnd=_iso(row['window_end']), generatedAt=_iso(row['created_at']),
                  summary=projection['summary'], model=row['model'], sourceCount=len(ids), sourceComplete=complete,
                  sourcesTruncated=bool(ids), topics=[], findings=[], sources=[], briefing=_remap(briefing, mapping),
                  scope=dict(groupNames=sorted(set(item['group'] for item in messages)), timeZone='Asia/Shanghai',
                             timeBasis='notification_observed_at', dataCutoff=_iso(max(known_times)) if known_times else None,
                             frozenCount=len(ids), analyzedCount=len(ids), readableCount=len(messages),
                             missingCount=len(ids)-len(messages), unknownTimeCount=len(times)-len(known_times),
                             completeChatHistory=False, externalVerification=False))
    core_ids = set(references(report['briefing']))
    while True:
        used = core_ids | {ref for card in exported for ref in card['sourceMessageIDs']}
        metadata = []
        for event_id in ids:
            if mapping[event_id] not in used:
                continue
            item = by_id.get(event_id)
            timestamp = _epoch(item.get('observedAt')) if item else None
            metadata.append(dict(id=mapping[event_id], available=item is not None,
                                 group=(item.get('group') or item.get('groupName') or '未知群') if item else None,
                                 sender=(item.get('sender') or item.get('senderDisplayName') or None) if item else None,
                                 observedAt=_iso(timestamp) if timestamp is not None else None))
        report['sourceReferences'] = metadata
        report['caDiscussions'] = exported
        report['caCoverage'] = dict(sourcesComplete=complete, totalItems=cards['total'], exportedItems=len(exported),
                                    truncated=len(exported) < cards['total'])
        payload = dict(schemaVersion=2, type='report', report=report)
        if len(metadata) <= 500:
            try:
                encode_payload(payload)
                return payload
            except SyncError as error:
                if error.code != 'payload_too_large' or not exported:
                    raise
        require(bool(exported), 'payload_too_large')
        exported.pop()


def build_report(row, source_messages, device_id, store_id):
    failure = None
    try:
        return _build(row, source_messages, device_id, store_id)
    except SyncError as error:
        failure = error.code
    except BriefingError as error:
        failure = error.code
    except (KeyError, TypeError, ValueError, OverflowError, RecursionError):
        failure = 'source_invalid'
    raise SyncError(failure)


def prepare_reports(analysis_path, messages_path, after_id, device_id, store_id):
    prepared = []
    repository = MessageRepository(messages_path, None)
    for row in completed_after(analysis_path, after_id):
        failure = None
        try:
            ids = _ids(row)
            messages = repository.by_event_ids(ids, include_canonical_identity=True)
            payload = encode_payload(build_report(row, messages, device_id, store_id))
        except MessageSourceUnavailable:
            raise SyncError('source_unavailable') from None
        except SyncError as error:
            failure = error.code
        except (KeyError, TypeError, ValueError, RecursionError):
            failure = 'source_invalid'
        prepared.append(dict(cursor=row['analysis_id'], payload=None if failure else payload, error_code=failure))
    return prepared
