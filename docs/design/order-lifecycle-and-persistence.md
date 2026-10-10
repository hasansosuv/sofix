# Order lifecycle: identifiers, correlation, storage and persistence by TIF, draft 2026-10-10

Requirement (Roma, 2026-10-10): store every message and the order state so that we can reject unknown amends/cancels, link everything into one lifecycle (new, ack, partial fills, amends, fills, busts, corrections), show it when a user clicks the order, and keep order state according to time in force (day orders for the day, GTC/GTD until expiry or user action). Unique-id tags must be configurable per message type. ClOrdID is unique per session, not across sessions.

Builds on oems-design-v0.md section 4 (identifiers and message-level rules) and order-hierarchy.md (parent/child).

---

## 1. Identifier tags configurable per message type

A `MessageKeyConfig` per session (with a default profile) says, for each message type, which tags identify the message itself and which tags point to an earlier message:

| MsgType | Own id | Refers to | Notes |
|---|---|---|---|
| D NewOrderSingle, AB NewOrderMultileg, E NewOrderList | 11 ClOrdID (E: also 66 ListID) | none | |
| G CancelReplace, AC MultilegCancelReplace | 11 | 41 OrigClOrdID, optional 37 | |
| F OrderCancelRequest | 11 | 41, optional 37 | |
| H OrderStatusRequest | 790 OrdStatusReqID | 11 and/or 37 | |
| 8 ExecutionReport (from the next broker) | 17 ExecID | 11 (our child ClOrdID), 37 (their OrderID), 19 ExecRefID on bust/correct | |
| 9 OrderCancelReject | none | 11, 41, 37 | |
| Q DontKnowTrade | none | 37, 17 | |
| J Allocation, others (later) | 70 AllocID, … | as configured | |

Defaults follow the FIX spec; a session can override a row, e.g. a client that sends its own id in 526 SecondaryClOrdID, or a counterparty that only sends 37 on cancels. The config is compiled once into a lookup table, so the hot path does no string work.

## 2. Uniqueness scope

* ClOrdID is unique **per (session, client)**, never across sessions (Roma, 2026-10-10). On a hub session (NYFIX, Autex) the client from 115 is part of the key, because two clients can send the same ClOrdID.
* Duplicate check: a new D whose 11 already belongs to a **live** order, or to any order of the same trading day, in that scope → reject (ER 39=8, 103=6 Duplicate order). Exception: PossResend 97=Y / PossDupFlag 43=Y with identical content → do not process again; resend the last state.
* GTC orders keep their ClOrdIDs in the index for as long as they live, so a new order on a later day cannot reuse a ClOrdID of a still-working GTC order.

## 3. The amend / cancel chain

Exactly as Roma described: the nth amend's 41 carries the ClOrdID (11) of the (n−1)th request; the first amend's 41 is the 11 of the original D.

```
D   11=A          new order
G   11=B  41=A    1st amend
G   11=C  41=B    2nd amend
F   11=D  41=C    cancel
```

* Every ClOrdID in the chain points to the same internal `orderKey`.
* G or F with a 41 that is not in the index → **OrderCancelReject 35=9, 102=1 Unknown order** (434=2 for G, 434=1 for F). Same for a 37 that does not match.
* 41 that is known but not the **latest** ClOrdID of the chain: per-session policy `STRICT` (reject) or `LENIENT` (accept, resolve via the chain); default STRICT.
* The other G/F rules (too late to cancel, already pending, quantity below CumQty, changing Symbol/Side) are in oems-design-v0.md section 4.2.

## 4. Tag 37 and how ExecutionReports are linked (clarification)

Small correction to the message: 37 does not contain 11. They are two separate identifiers that travel together:

* **On the broker side we are the ones who assign 37 (OrderID).** We generate it once when the order is accepted, and it stays the same for the whole life of the order through all amends. Every ER we send carries both the client's current 11 and our 37. Internally we keep the maps `ClOrdID → orderKey` and `OrderID → orderKey`, so either one finds the order.
* **ERs received from the next broker** (STREET child orders, order-hierarchy.md): their 37 is *their* OrderID. We match the ER by the 11 we generated for the child (unique across the whole deployment), which gives the child, which gives the parent client order. Their 37 is stored on the child as a second key, for messages that only carry 37 (some cancels, DK, busts).

## 5. Executions, busts and corrections

* Each ER has 17 ExecID, unique; stored in an `execution` table linked to the order. Duplicates (same 17) are ignored.
* Bust: 150=H Trade Cancel, 19 ExecRefID = the 17 of the busted fill. CumQty, AvgPx and LeavesQty are recalculated without that fill; the order may go back from Filled to Partially Filled.
* Correction: 150=G Trade Correct, 19 = the 17 being corrected, with the new LastQty / LastPx. Recalculated the same way.
* FIX 4.2 uses 20 ExecTransType (1 Cancel, 2 Correct) instead of 150=H/G; the version normalizer maps both to the same internal event.
* On the broker side we produce busts and corrections ourselves (trader action in the UI, referencing the fill to bust). A bust / correction from the next broker on a child is rolled up to the parent and, per the manual/auto policy, sent to the client as a bust / correction of the matching client fill.
* Busts and corrections are allowed even after the order is Filled or Done for day, within a configurable window.

## 6. What is stored

| Table | Contents | Used for |
|---|---|---|
| `fix_message` | Every message in and out, raw text + parsed key columns (session, client, direction, MsgType, MsgSeqNum, 11, 41, 37, 17, 19, sending time) + `order_key` once linked | Lifecycle view, audit, debugging; 1-year retention |
| `orders` | Current state per order (one row per orderKey): ids, client, user, side, symbol, qty, price, TIF, ExpireDate, OrdStatus, CumQty, AvgPx, LeavesQty, parent/root, version | Blotter, recovery |
| `order_version` | One row per accepted request (D, each accepted G) with its fields | "What did the order look like after amend 2" |
| `execution` | Every fill, bust and correction with 17 / 19 links | Positions, bust/correct, reports |
| `order_event` | Every change to an order with actor CLIENT / TRADER / AUTO / BROKER (next broker, on street children) / SYSTEM, event type, state after, reason, user id, link to the FIX message; rejected requests recorded too | Lifecycle view, audit |

**Lifecycle view**: clicking an order loads all rows with that orderKey (and its children's) ordered by an internal event sequence number (not timestamps, which can tie): New → Ack → Partial → Amend request → Amend ack → Partial → … → Fill → Bust → Correct, each expandable to the raw FIX message, and rejected requests shown too (e.g. the G with unknown 41).

Both sides in one view (Roma, 2026-10-10): the client order's messages (client session) and all its children's messages (next broker's session, our outbound D/F/G and their ERs, linked because their ERs echo our child ClOrdID in 11) are merged into one timeline with columns side (CLIENT / STREET), direction, session, message. Default layout (Roma, 2026-10-10): **two panels side by side**, Client side (left) and Street side (right, with a child selector: all children or one), rows aligned by time so a broker fill and the client fill it produced sit on the same line; clicking a row highlights the linked row on the other side. A toggle switches to the single merged timeline. Anyone allowed to see the client order sees its street messages.

## 7. Persistence by time in force

Two kinds of order state, as Roma described:

| | Day orders (59=0, and IOC/FOK which end at once) | Multi-day orders (59=1 GTC, 59=6 GTD, 59=2 OPG / 7 close end same day) |
|---|---|---|
| Live (in memory + `orders` table) | Until filled / cancelled / rejected, or the session's end of day: the `DoneForDayJob` / `ExpireOrdersJob` sends DFD or expires it (manual or auto per policy) | Carried over every trading day by `OrderCarryOverJob` until filled, cancelled, expired at 126 ExpireTime / 432 ExpireDate (GTD), or closed by the user |
| After that | Order leaves the live set and the in-memory index; it stays in history (`orders`, `fix_message`, `execution`) | Same, once closed |

* **A user cannot silently delete a live GTC/GTD order**: the client still thinks it is working. "Delete" in the UI is an **expire / cancel** action that sends the client an ER (39=C Expired or 39=4 Canceled), manual or auto per policy, and then the order leaves the live set. Optional per profile: maximum life of a GTC order (e.g. 90 days), after which the expire job closes it.
* **Retention**: the 1-year retention counts from the date the order **closed**, not from the date of the message. A GTC order still working after 13 months keeps its whole history; partitions are only dropped for orders closed more than a year ago.
* **Restart**: see section 7b.
* "Trading day" is per session: time zone and end-of-day time are session business settings (e.g. 17:00 New York).

## 7b. Crash and intraday restart (Roma, 2026-10-10)

Nothing that was acknowledged is lost. Builds on oems-design-v0.md section on persistence (journal first, database second).

**While running**
1. Every inbound message and every state change is appended to the local journal (Chronicle Queue, on disk) **before** we send anything back. Rule: no ER, ack or cancel-reject leaves the engine until the change that caused it is in the journal.
2. PostgreSQL is filled asynchronously from the journal, so it can lag by a few milliseconds; the journal is the source of truth.
3. QuickFIX/J keeps its own store of sequence numbers and sent messages (JDBC store in PostgreSQL, or file store), separate from our journal.
4. Pending manual work (orders waiting for a trader to ack, fill or accept a cancel) is ordinary order state, so it is journaled too.

**On restart** (`LiveOrderRecovery`, before any FIX session is started)
1. Load live orders from PostgreSQL (today's day orders + all open GTC/GTD).
2. Replay the journal entries after the last one the database writer confirmed, so the few milliseconds the database was behind are recovered.
3. Rebuild the in-memory indexes (ClOrdID, OrderID, ExecID) and the manual-action queues.
4. Only then start the FIX sessions. QuickFIX/J logs on with the stored sequence numbers: the counterparty resends anything we missed while down (ResendRequest), and we resend what they missed (from our store, or as gap fill per session setting for stale messages).
5. Messages resent with PossDupFlag 43=Y that we already processed are recognised by ClOrdID / ExecID and not processed twice.
6. UI clients reconnect; the BFF resumes the event stream from the last event number it received.

**Edge cases**
* Crash after journaling but before the ER was sent: on restart the engine sees the ER was not in the QuickFIX/J sent store and sends it.
* Disk loss of the journal itself: covered later by HA (journal replicated to a standby, oems-design-v0.md decision D8). v1: single instance, journal on a durable disk.
* Day roll while down: if the restart happens after the session's end of day, the end-of-day job runs first (DFD / expire day orders), then sessions start.

Test to have from day 1: kill the process (kill -9) in the middle of a burst of orders and fills, restart, and check that every order's state, CumQty and the FIX sequence numbers match what the counterparty saw.

## 8. Other things to settle (what else to discuss)

1. **Trading day and end of day** per session: time zone, cut-off time, holidays (TradingCalendar).
2. **Duplicates and resends**: PossDupFlag 43 / PossResend 97 handling (section 2), and what to send back.
3. **Requests that cross**: a cancel arriving while an amend is pending; a fill arriving while a cancel is pending (FIX allows the fill; the cancel then applies to the rest).
4. **Unsolicited changes** from our side: unsolicited cancel, restatement (150=D), DFD, expiry; all go through the same state machine with actor TRADER / AUTO.
5. **Order status request (H)**: answer with an ER 150=I for the current state, or 'unknown order'.
6. **Don't Know Trade (Q)** from the client: alert the trader, no state change.
7. **Multi-leg (AB/AC) and lists (E)**: legs keyed by 654 LegRefID; list orders by 66 ListID; one lifecycle per order, grouped by list.
8. **Busts / corrections window** (section 5) and who may bust.
9. **What the client is told when a user closes a GTC order** (section 7): question to Roma.

## 9. Outline changes

| Interface | Default | Placeholder |
|---|---|---|
| `MessageKeyConfig` | FIX-standard table of section 1 | Per-session overrides |
| `OrderIndex` | In-memory maps per (session, client): ClOrdID → orderKey, OrderID → orderKey, ExecID set | n/a (core) |
| `OrigClOrdIdPolicy` | `STRICT` | `LENIENT` |
| `ExecutionRepository` | In memory | PostgreSQL |
| `OrderLifecycleQuery` | Loads messages, versions, executions, events for an orderKey tree | n/a |
| `OrderPersistencePolicy` | DAY: close at end of day; GTC/GTD: carry over | Max GTC life per profile |
| `LiveOrderRecovery` | Reload live orders and rebuild `OrderIndex` at startup | n/a |
