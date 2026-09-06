"""Signal v2 outbound contract. Pure validation; no I/O or source verification.

The exporter must verify original source/address evidence before mapping IDs.
This boundary never fabricates source evidence from the outgoing document.
"""
import datetime
import json
import re
import unicodedata

from .briefing import BriefingError, references, validate_briefing


MAX_BODY_BYTES = 262144
NETWORKS = frozenset('base bsc ethereum arbitrum polygon optimism avalanche solana'.split())
REPORT_KEYS = 'id revision cadence windowStart windowEnd generatedAt summary model sourceCount sourceComplete sourcesTruncated topics findings sources briefing scope sourceReferences caDiscussions caCoverage'
ALERT_KEYS = 'id revision address network groups groupCount mentionCount uniqueStatementCount duplicateCount firstSeenAt lastSeenAt triggeredAt evaluatedAt expiresAt windowSeconds thresholdGroups status notificationVersion catchup'
HEARTBEAT_KEYS = 'listener worker pendingReports lastError caDetector pendingAlerts lastMessageObservedAt lastCaEvaluatedAt'
_SENSITIVE = re.compile(r'(?i)(?:\bsk-(?:cp-)?[a-z0-9_-]{20,}|\bAKIA[A-Z0-9]{16}\b|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bbearer\s+[a-z0-9._~-]{16,}|(?:api[_ -]?key|secret|password|密码)\s*[:=]\s*["\']?[^\s"\']{8,})')


class SyncError(ValueError):
    """Fixed local error code only. Never include a request or raw exception."""
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def require(condition, code='payload_invalid'):
    if not condition:
        raise SyncError(code)


def exact(value, keys):
    require(type(value) is dict and set(value) == set(keys.split()))


def integer(value, minimum=0):
    require(type(value) is int and minimum <= value <= 9007199254740991)


def text(value, maximum):
    require(type(value) is str and bool(value.strip()))
    require(len(value.encode('utf-16-le')) // 2 <= maximum)
    require(not any(unicodedata.category(c) == 'Cc' and c not in '\t\r\n' for c in value))


def timestamp(value):
    text(value, 40)
    require(re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|\+00:00)', value))
    return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()


def rows(value, maximum):
    require(type(value) is list and len(value) <= maximum)
    return value


def groups(value):
    for group in rows(value, 50):
        text(group, 200)
    require(len(set(value)) == len(value))


def _scan(value):
    pending = [(value, 0)]
    visited = 0
    text_bytes = 0
    while pending:
        item, depth = pending.pop()
        visited += 1
        require(depth <= 20 and visited <= 20000)
        if type(item) is str:
            text(item, MAX_BODY_BYTES)
            text_bytes += len(item.encode('utf-8'))
            require(text_bytes <= MAX_BODY_BYTES, 'payload_too_large')
            require(not _SENSITIVE.search(item), 'payload_sensitive')
        elif type(item) is dict:
            require(len(item) <= 100)
            for key, child in item.items():
                text(key, 200)
                pending.append((child, depth + 1))
        elif type(item) is list:
            require(len(item) <= 1000)
            pending.extend((child, depth + 1) for child in item)
        else:
            require(item is None or type(item) in (bool, int))


def _counting(value):
    for key in ('mentionCount', 'uniqueStatementCount', 'duplicateCount'):
        integer(value[key])
    require(value['mentionCount'] == value['uniqueStatementCount'] + value['duplicateCount'])
    require(value['mentionCount'] >= len(value['groups']))


def _report(report):
    exact(report, REPORT_KEYS)
    require(report['cadence'] in ('two_hour', 'six_hour', 'daily'))
    require(timestamp(report['windowStart']) < timestamp(report['windowEnd']))
    timestamp(report['generatedAt'])
    text(report['summary'], 10000)
    text(report['model'], 256)
    integer(report['sourceCount'])
    require(type(report['sourceComplete']) is bool and type(report['sourcesTruncated']) is bool)
    require(report['sourcesTruncated'] == (report['sourceCount'] > 0))
    require(report['topics'] == report['findings'] == report['sources'] == [])
    scope = report['scope']
    exact(scope, 'groupNames timeZone timeBasis dataCutoff frozenCount analyzedCount readableCount missingCount unknownTimeCount completeChatHistory externalVerification')
    groups(scope['groupNames'])
    require(scope['timeZone'] == 'Asia/Shanghai' and scope['timeBasis'] == 'notification_observed_at')
    for key in ('frozenCount', 'analyzedCount', 'readableCount', 'missingCount', 'unknownTimeCount'):
        integer(scope[key])
    require(scope['frozenCount'] == scope['analyzedCount'] == report['sourceCount'])
    require(scope['readableCount'] + scope['missingCount'] == scope['frozenCount'])
    require(scope['unknownTimeCount'] <= scope['readableCount'])
    require(len(scope['groupNames']) <= scope['readableCount'])
    require(scope['completeChatHistory'] is False and scope['externalVerification'] is False)
    require(report['sourceComplete'] == (scope['missingCount'] == 0))
    known_time_count = scope['readableCount'] - scope['unknownTimeCount']
    require((scope['dataCutoff'] is not None) == (known_time_count > 0))
    cutoff = timestamp(scope['dataCutoff']) if scope['dataCutoff'] is not None else None
    metadata = rows(report['sourceReferences'], 500)
    ids = set()
    available_count = missing_count = unknown_time_count = 0
    for ref in metadata:
        exact(ref, 'id group sender observedAt available')
        text(ref['id'], 32)
        require(re.fullmatch(r'M[0-9]{4,}', ref['id']))
        require(1 <= int(ref['id'][1:]) <= report['sourceCount'] and ref['id'] not in ids)
        ids.add(ref['id'])
        require(type(ref['available']) is bool)
        if not ref['available']:
            missing_count += 1
            require(all(ref[key] is None for key in ('group', 'sender', 'observedAt')))
        else:
            available_count += 1
            unknown_time_count += int(ref['observedAt'] is None)
        for key in ('group', 'sender'):
            if ref[key] is not None:
                text(ref[key], 200)
        if ref['group'] is not None:
            require(ref['group'] in scope['groupNames'])
        if ref['observedAt'] is not None:
            require(cutoff is not None and timestamp(ref['observedAt']) <= cutoff)
    require(available_count <= scope['readableCount'] and missing_count <= scope['missingCount'])
    require(unknown_time_count <= scope['unknownTimeCount'])
    validate_briefing(report['briefing'], ids)
    used = set(references(report['briefing']))
    for ca in rows(report['caDiscussions'], 50):
        exact(ca, 'address network groups mentionCount uniqueStatementCount duplicateCount summary sourceMessageIDs')
        text(ca['address'], 128)
        require(ca['network'] in NETWORKS | {'unknown'})
        groups(ca['groups'])
        require(set(ca['groups']) <= set(scope['groupNames']))
        require(ca['network'] != 'unknown' or len(ca['groups']) <= 1)
        _counting(ca)
        require(ca['mentionCount'] <= scope['readableCount'])
        if ca['summary'] is not None:
            text(ca['summary'], 2000)
        for ref in rows(ca['sourceMessageIDs'], 5):
            require(type(ref) is str and ref in ids)
            used.add(ref)
    require(used == ids)
    coverage = report['caCoverage']
    exact(coverage, 'sourcesComplete totalItems exportedItems truncated')
    require(type(coverage['sourcesComplete']) is bool and type(coverage['truncated']) is bool)
    integer(coverage['totalItems'])
    integer(coverage['exportedItems'])
    require(coverage['sourcesComplete'] == report['sourceComplete'])
    require(coverage['exportedItems'] == len(report['caDiscussions']) <= coverage['totalItems'])
    require(coverage['truncated'] == (coverage['exportedItems'] < coverage['totalItems']))


def _alert(item):
    exact(item, ALERT_KEYS)
    text(item['address'], 128)
    require(item['network'] in NETWORKS)
    groups(item['groups'])
    integer(item['groupCount'], 2)
    require(item['groupCount'] == len(item['groups']))
    _counting(item)
    for key in ('windowSeconds', 'thresholdGroups', 'notificationVersion'):
        integer(item[key])
    require(item['windowSeconds'] == 3600 and item['thresholdGroups'] == 2)
    require(item['notificationVersion'] in (0, 1) and item['notificationVersion'] <= item['revision'])
    require(type(item['catchup']) is bool)
    require(not item['catchup'] or item['notificationVersion'] == 0)
    times = {key: timestamp(item[key]) for key in ('firstSeenAt', 'lastSeenAt', 'triggeredAt', 'evaluatedAt', 'expiresAt')}
    require(item['status'] in ('active', 'expired'))
    require(times['firstSeenAt'] <= times['lastSeenAt'] <= times['evaluatedAt'])
    require(times['triggeredAt'] <= times['evaluatedAt'])
    if item['status'] == 'active':
        require(times['evaluatedAt'] - 3600 < times['firstSeenAt'] and times['evaluatedAt'] < times['expiresAt'])


def _validate(value):
    _scan(value)
    require(type(value) is dict)
    require(type(value.get('schemaVersion')) is int and value['schemaVersion'] == 2, 'unsupported_schema')
    kind = value.get('type')
    child = {'report': 'report', 'ca_alert': 'alert', 'heartbeat': 'status'}.get(kind)
    require(child is not None)
    exact(value, 'schemaVersion type ' + child)
    item = value[child]
    if kind != 'heartbeat':
        require(type(item) is dict)
        text(item['id'], 1024)
        require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._:-]*', item['id']))
        integer(item['revision'], 1)
    if kind == 'report':
        _report(item)
    elif kind == 'ca_alert':
        _alert(item)
    else:
        exact(item, HEARTBEAT_KEYS)
        for key in ('listener', 'worker', 'caDetector'):
            require(item[key] in ('online', 'offline', 'unknown'))
        for key in ('pendingReports', 'pendingAlerts'):
            integer(item[key])
        for key in ('lastMessageObservedAt', 'lastCaEvaluatedAt'):
            if item[key] is not None:
                timestamp(item[key])
        require(item['lastError'] is None or re.fullmatch(r'[a-z][a-z0-9_]{0,79}', item['lastError']))


def encode_payload(value):
    failure = None
    try:
        _validate(value)
        body = json.dumps(value, ensure_ascii=False, allow_nan=False,
                          sort_keys=True, separators=(',', ':')).encode('utf-8')
        require(len(body) <= MAX_BODY_BYTES, 'payload_too_large')
    except SyncError as error:
        failure = error.code
    except (BriefingError, TypeError, ValueError, KeyError, OverflowError, RecursionError, OSError):
        failure = 'payload_invalid'
    if failure is not None:
        raise SyncError(failure)
    return body


def validate_payload(value):
    encode_payload(value)
