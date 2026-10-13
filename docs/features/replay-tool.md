# Feature: Replay Tool

Status: built 2026-10-13. sofix-oems `d4e0125`; sofix-ui-be `2680d2e`; sofix-ui-fe `e904a84`.
Both sides (SELL_SIDE and BUY_SIDE). Sending needs **Execute** on the Replay Tool panel.

## 1. What the user does

1. FIX Utilities → **Replay Tool** → drop or choose a **FIX log file**. Every message is found:
   anywhere in a line from `8=FIX`, fields separated by SOH, `|` or `^A`, several per line allowed.
2. Choose the **Session**: only sessions of the file's FIX version can be chosen; it must be
   logged on to send.
3. Options: **Pause (ms)** between messages; **Only from (49)** one sender of the log; **New
   ClOrdIDs** (11 becomes `<11>-R<run>`, 41 follows when it names a replayed order); **TransactTime
   (60) now**; **Include session messages** (logon, heartbeat… are skipped by default); **Skip
   BodyLength / CheckSum mismatches** (on by default).
4. **Replay**: messages go out one by one; **Pause / Resume / Stop**. The header shows the counts
   (to send, sent, skipped, failed); each row its outcome and detail (the MsgSeqNum it went with,
   or why it was skipped or failed). A notification at the end.
5. **Single message**: paste one message and **Send Message** (same options).

## 2. Flow

```mermaid
sequenceDiagram
  participant UI as Replay Tool
  participant BE as sofix-ui-be
  participant O as OEMS
  participant CP as Counterparty
  UI->>UI: parse the log, mark skipped messages, apply options (11/41, 60)
  loop each message to send
    UI->>BE: POST /api/sessions/{id}/replay { message }
    BE->>O: same (Execute on replay-tool checked)
    O->>O: version check; recompute 9 and 10; read with the session's dictionary (groups kept);
    O->>O: drop 49, 56, 34, 52, 43, 97, 122
    O->>CP: send on the session (its CompIDs, next MsgSeqNum, SendingTime)
    O-->>UI: { msgSeqNum }
  end
```

## 3. Rules and tests

| Rule | Where | Test |
|---|---|---|
| Finding messages; corrupted (damaged field, cut short, no 8 / 35); BodyLength / CheckSum check | `domain/fix-log.ts` | `fix-log.spec.ts` |
| New ClOrdIDs with 41 following; TransactTime now | `rewrite` in `fix-log.ts` | `fix-log.spec.ts` |
| Only the session's FIX version | `SessionControlService.replay` (OEMS-SES-0011) | `SessionControlServiceTest` |
| Logged on only (OEMS-SES-0010); header replaced; groups kept | `QuickFixJSessionConnector.sendRaw`, `RawFixText` | `QuickFixJSessionConnectorTest` |
| Whole flow | two throwaway OEMS + backend + browser | manual check 2026-10-13 |

## 4. Known limitations

1. Messages are sent as they are (after the options): replayed orders are not checked by the
   OEMS's order book on the sending side, and the answers they get are handled as for any order
   (e.g. a buy-side OEMS logs answers for ClOrdIDs it does not know).
2. One message per HTTP call, paced by the browser: closing the panel or the browser stops a run.
3. Timing of the original log (52) is not reproduced; a fixed pause is used.
4. Data fields and repeating groups are read with the session's dictionary; a message that does
   not match it (e.g. a custom message type the dictionary lacks) fails with OEMS-SES-0011.
