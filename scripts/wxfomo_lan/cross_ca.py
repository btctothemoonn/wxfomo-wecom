"""Local, source-backed CA discussion cards; no price service or extra AI calls."""

import datetime
import re
import unicodedata

from .minimax import _EVM_ADDRESS, _SOLANA_ADDRESS, _SOLANA_CUE, _base58_decoded_size


_NETWORKS = {"base": "base", "bsc": "bsc", "eth": "ethereum", "ethereum": "ethereum",
             "arb": "arbitrum", "arbitrum": "arbitrum", "polygon": "polygon",
             "optimism": "optimism", "avalanche": "avalanche"}
_CHAIN_PREFIX = re.compile(
    r"(?:^|\s)(base|bsc|eth|ethereum|arb|arbitrum|polygon|optimism|avalanche)"
    r"\s*(?:链)?\s*(?:CA|合约|地址)?\s*[:：]?\s*$", re.I
)
_EXPLORERS = {"etherscan.io": "ethereum", "basescan.org": "base", "bscscan.com": "bsc",
              "arbiscan.io": "arbitrum", "polygonscan.com": "polygon",
              "optimistic.etherscan.io": "optimism", "snowtrace.io": "avalanche"}
_EXPLORER_PREFIX = re.compile(r"https://([^/\s]+)/(?:address|token)/$", re.I)


def address_mentions(content):
    """Return direct CA evidence while preserving the first display spelling."""
    if not isinstance(content, str):
        return []
    seen = set()
    result = []
    for match in _EVM_ADDRESS.finditer(content):
        prefix = content[max(0, match.start()-100):match.start()]
        explorer = _EXPLORER_PREFIX.search(prefix)
        chain = _CHAIN_PREFIX.search(prefix)
        network = (_EXPLORERS.get(explorer.group(1).lower(), "unknown") if explorer else
                   _NETWORKS[chain.group(1).lower()] if chain else "unknown")
        address = match.group(0)
        key = (address.lower(), network)
        if key not in seen:
            seen.add(key)
            result.append(dict(address=address, normalizedAddress=key[0], network=network))
    for match in _SOLANA_ADDRESS.finditer(content):
        address = match.group(0)
        if _base58_decoded_size(address) == 32 and (content.strip() == address or _SOLANA_CUE.search(content)):
            key = (address, "solana")
            if key not in seen:
                seen.add(key)
                result.append(dict(address=address, normalizedAddress=address,
                                   network="solana"))
    return result


def _mentions(content):
    return sorted((item["normalizedAddress"], item["network"])
                  for item in address_mentions(content))


def _context_owners(messages, keys):
    """Match the AI's +/-2 messages, same-group, <5min evidence window.

    A context-only message shared by several CA/chain buckets is ambiguous;
    never assign its summary to one arbitrarily. Direct counts stay unchanged.
    """
    times = []
    for message in messages:
        try:
            times.append(datetime.datetime.fromisoformat(
                message['observedAt'].replace('Z', '+00:00')).timestamp())
        except (KeyError, AttributeError, ValueError, TypeError, OverflowError, OSError):
            times.append(None)
    owners = {}
    for index, message_keys in enumerate(keys):
        if not message_keys:
            continue
        owners.setdefault(messages[index]['eventId'], set()).update(message_keys)
        for nearby in range(max(0, index - 2), min(len(messages), index + 3)):
            candidate = messages[nearby]
            if (keys[nearby] or times[index] is None or times[nearby] is None
                    or abs(times[index] - times[nearby]) >= 300
                    or candidate.get('group') != messages[index].get('group')):
                continue
            if candidate.get('eventId'):
                owners.setdefault(candidate['eventId'], set()).update(message_keys)
    return owners


def cross_ca_cards(messages, summaries):
    keys = [set((address, network, (message.get('group') or '未知群') if network == 'unknown' else '')
                for address, network in _mentions(message.get('content') or '')) for message in messages]
    owners = _context_owners(messages, keys)
    contexts = {}
    for event_id, candidates in owners.items():
        if len(candidates) == 1:
            contexts.setdefault(next(iter(candidates)), set()).add(event_id)
    buckets = {}
    for index, message in enumerate(messages):
        content = message.get("content", "")
        event_id = message.get("eventId")
        if not isinstance(content, str) or not event_id:
            continue
        group, speaker = message.get("group") or "未知群", message.get("sender") or ""
        canonical = " ".join(unicodedata.normalize("NFC", content).split())
        canonical = _EVM_ADDRESS.sub(lambda m: m.group(0).lower(), canonical)
        for key in sorted(keys[index]):
            address, network, _ = key
            # Unknown EVM chains are not evidence of the same token across groups.
            bucket = buckets.setdefault(key, dict(groups=set(), speakers=set(), statements=set(), ids=[], seen=set(), times=[]))
            if event_id in bucket["seen"]:
                continue
            bucket["seen"].add(event_id)
            bucket["ids"].append(event_id)
            bucket["groups"].add(group)
            if speaker:
                bucket["speakers"].add(speaker)
            bucket["statements"].add((speaker or event_id, canonical))
            if isinstance(message.get("observedAt"), str):
                bucket["times"].append(message["observedAt"])
    cards = []
    for key, bucket in buckets.items():
        address, network, _ = key
        ids = set(bucket["ids"])
        summary = None
        unavailable_reason = None
        selected = []
        for item in summaries:
            normalized = item.get("normalizedAddress", item.get("address"))
            sources = item.get("sourceMessageIDs", [])
            if normalized != address:
                continue
            unavailable_reason = 'unresolved_sources'
            if sources and set(sources).issubset(contexts.get(key, set())):
                summary = item.get("contextSummary")
                unavailable_reason = None
                selected.extend(sources)
                break
        selected = list(dict.fromkeys(selected + bucket["ids"]))[:5]
        count, unique = len(ids), len(bucket["statements"])
        cards.append(dict(address=address, network=network, groupNames=sorted(bucket["groups"]),
                          groupCount=len(bucket["groups"]), speakers=sorted(bucket["speakers"])[:50],
                          speakerCount=len(bucket["speakers"]), mentionCount=count,
                          uniqueStatementCount=unique, duplicateCount=count-unique,
                          firstSeenAt=min(bucket["times"]) if bucket["times"] else None,
                          lastSeenAt=max(bucket["times"]) if bucket["times"] else None,
                          summary=summary, summaryUnavailableReason=unavailable_reason,
                          sourceMessageIDs=selected))
    cards.sort(key=lambda c: (-c["groupCount"], -c["uniqueStatementCount"], c["address"], c["network"]))
    return {"items": cards[:50], "total": len(cards)}
