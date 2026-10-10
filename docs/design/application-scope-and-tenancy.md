# Application scope, client companies and order visibility, revised 2026-10-10

History: drafts on 2026-10-09 and earlier on 2026-10-10 proposed multi-tenancy (several brokers on one platform, users per company, modules per company). **Roma rejected that on 2026-10-10.** This file now describes the agreed single-owner model. Scope of this document: the **broker (sell) side only**. The buy side is a separate topic, discussed later.

---

## 0. The model (Roma, 2026-10-10)

* **One owner.** SOFIX is run by one broker, the application owner. It is not given to other brokers. There are no tenants.
* **All users belong to the owner**: traders, sales traders, ops, testers, managers, admins. Users never belong to a client.
* **Companies are clients.** A "company" is a buy-side firm that sends orders to the owner. It is a record (name, sessions, accounts, identifiers), it has **no users and no login**.
* A client reaches us either through a **dedicated point-to-point session**, or through a **hub** such as NYFIX or Autex, where one session carries orders from many clients.

```
Application owner (the broker running SOFIX)
 ├─ Users: traders, sales traders, ops, testers, managers, admins
 │
 └─ Client companies (records, no login)
      ├─ Fidelity    ── dedicated session FIDELITY_IN
      ├─ Vanguard    ── via NYFIX session, 115 = VANG
      └─ BlackRock   ── via NYFIX (115 = BLKR) and via Autex (115 = BLK)
```

## 1. Identifying the client of an inbound order

| Session type | Example | How the client is found |
|---|---|---|
| `DEDICATED` | Fidelity connects directly | The client configured on the session. Tags in the message cannot change it. |
| `HUB` (NYFIX, Autex, other networks) | One NYFIX session carries orders from Vanguard, BlackRock, … | From a configurable tag, default **115 OnBehalfOfCompID** (49 is the hub's own CompID). The value is looked up in `client_hub_identity` (each client's identifier per hub). |

```yaml
session: NYFIX_IN
sessionType: HUB
hub: NYFIX
clientResolution:
  tags: [ { tag: 115, location: HEADER } ]   # ordered list, like the user tags
  onNoMatch: REJECT    # missing / unknown -> ER 39=8, 58 "Client details missing" (manual mode later: unmatched queue)
```

Rules on a hub session:
* Cancels and replaces follow the order chain, **and** their 115 must resolve to the same client as the original order; otherwise they are rejected (OrderCancelReject 9, 58 "Order belongs to another firm"). One client can never cancel another client's order by guessing a ClOrdID.
* ClOrdID uniqueness and order-chain lookups are per (session, client), since two clients on the same hub can send the same ClOrdID.
* Replies are routed back by the template echo rule: 115 → 128 DeliverToCompID, 116 → 129 DeliverToSubID.

Every order stores `client_id` (never null once accepted), copied onto its messages, executions and events.

## 2. Identifying the user of an inbound order

* Users are all the owner's, so there is **one user namespace**. The earlier concern ("the same user name in two companies") no longer applies: 116 (and the alternative tags) is looked up in one alias table, aliases unique across the application (optionally per session). The alias table needs no company column.
* Order of resolution stays as in routing-inbound-order-to-user.md: order chain → configured tags → onNoMatch.
* **PROD (Roma, 2026-10-10):** on client orders 116 is the client's own trader, so our user comes from another tag, e.g. **57 TargetSubID** or **129 DeliverToSubID**. This is just the per-session ordered tag list already designed (routing-inbound-order-to-user.md section 2), e.g. PROD session: primary 57, alternative 129; UAT certification session: primary 116. 116 is always stored and shown as the client trader.
* onNoMatch stays configurable per session: REJECT ("User details missing"), UNASSIGNED, or COVERAGE (attribute to the users covering the client, section 3 #7). Proposed default: REJECT on UAT, COVERAGE on PROD, so a real client order is never rejected only because the broker-user tag is missing.

## 3. Client company data

| # | Area | Contents | v1? |
|---|---|---|---|
| 1 | Profile | Legal name, short code (unique), display name, type (ASSET_MANAGER, HEDGE_FUND, PENSION_FUND, BANK, BROKER_DEALER, FAMILY_OFFICE, OTHER), status (ONBOARDING, ACTIVE, SUSPENDED, CLOSED), country, time zone, addresses | yes |
| 2 | Identifiers | LEI, BIC, regulatory ids; FIX identities: CompIDs on dedicated sessions, identifier per hub (115 value on NYFIX, Autex…) | yes |
| 3 | Contacts | Trading desk, FIX / technical support, operations, compliance; name, email, phone | yes |
| 4 | Connectivity | Dedicated sessions of this client; hubs it uses (NYFIX, Autex…); UAT and PROD | yes |
| 5 | Accounts | Accounts and sub-accounts (tag 1), allocation accounts, settlement details | yes |
| 6 | Trading setup | Broker profile assigned to the client (validation rules, ER templates, auto/manual policy), allowed asset classes and order types, limits (per order, per day, credit) | yes |
| 7 | Coverage | Which of our users / teams cover this client (sales trader, trader); used for order visibility and attribution | yes |
| 8 | Certification | Certification status per session or hub, test results linked to the client | later |
| 9 | Audit | Who created / changed the client, status history | yes |

A SUSPENDED client's dedicated sessions are stopped and its orders on hub sessions are rejected; its data is kept.

## 4. Order visibility for our users

| Permission | Sees |
|---|---|
| `orders.view.own` | Orders attributed to themselves |
| `orders.view.clients` | Orders of the clients they cover (coverage, section 3 #7) |
| `orders.view.users` | Orders of specific users or teams chosen by an admin (e.g. a manager over A1, A2, A3) |
| `orders.view.all` | Every order, including unattributed ones |

* Seeing and acting are separate permissions (`orders.act.own / clients / users / all`), so a manager can watch everything and act only on some orders.
* Roles are built from these permissions by an admin in the UI (typical: Trader = own + clients, Manager = all view).
* Enforcement in the engine's `AccessPolicy` on every query and live event; the BFF only forwards an event to browsers whose user may see it.

## 5. Application scope

One application. The broker side is built first. The buy side (sending orders to other brokers, NYFIX / Autex as outbound routes, allocations) is a separate discussion later and is not designed here; the earlier outline placeholders for it stay as they are.

## 6. Outline changes

* Removed: `Company` (as tenant), `Module`, `TenantContext`, `ModuleEntitlementService`, `TenantContextProvider`, visibility values COMPANY / PLATFORM.
* Added: `ClientCompany`, `ClientId`, `SessionType` (DEDICATED, HUB); `ClientResolver` (default `SessionClientResolver`, `HubTagClientResolver` for 115); `UserContextProvider` (current user from the BFF token).
* `OwnedResource` keeps ownerUserId, visibility PRIVATE / GROUP / PUBLIC, groupId, sharedWithUserIds.

## 7. Buy side: SOFIX as a SaaS OEMS (proposed 2026-10-10, awaiting Roma)

Roma, 2026-10-10: from the buy-side perspective SOFIX is a **SaaS OEMS** operated by SOSUV. Buy-side firms (asset managers, hedge funds) are customer companies; their users log in and send orders to their brokers. Users must not see other companies' orders, and by default not other users' orders in their own company.

Here multi-tenancy is right, because the users now belong to the customers, not to the operator. Sections 0 to 6 (broker side, single owner) stay as decided.

### 7.1 Two deployments of the same build

| | Broker desk deployment | Buy-side SaaS deployment |
|---|---|---|
| Who runs it | One broker (the owner) for itself | SOSUV, for many buy-side firms |
| Users belong to | The owner | Each customer company |
| "Company" means | A client sending us orders (record, no login) | A customer (tenant) with its own users and login |
| FIX direction | Mostly inbound orders, outbound ERs | Outbound orders, inbound ERs |

Recommendation: **one codebase, two separate deployments**, chosen by configuration (`sofix.deployment.mode: BROKER_DESK | BUY_SIDE_SAAS`). Reasons: different customers, data and risk; a problem or upgrade on the SaaS side never touches the broker desk; each can scale and be certified separately. The broker desk can even be one of the brokers the SaaS customers route to, over normal FIX.

How the code stays one: **every engine record carries `tenant_id` from day one**. A broker desk deployment has exactly one tenant (the owner) created at install and never shown in the UI, so the broker-side model from this morning is unchanged. The SaaS deployment has one tenant per customer. Code never branches on the mode for data access; `AccessPolicy` always filters by tenant first.

### 7.2 Customer company (tenant)

* Profile (name, short code, type ASSET_MANAGER / HEDGE_FUND / …, status, addresses, LEI, contacts), entitlements (asset classes, limits, max users), contract dates.
* **Users belong to exactly one company.** Login name is globally unique (e.g. email), so the same person name in two companies is no problem.
* Company admin creates users, teams and roles; SOSUV platform admin creates companies. Platform staff do not see customer orders, except through a time-limited, audited support permission.
* Funds and accounts (tag 1), allocation accounts, brokers it trades with (broker connections), order presets, ticket templates, compliance rules.

### 7.3 Order visibility inside a company

Reuses section 4 with tenant isolation always applied first:

| Permission | Sees |
|---|---|
| `orders.view.own` (default) | Their own orders only |
| `orders.view.users` | Orders of users or teams an admin assigned (e.g. a PM over their traders) |
| `orders.view.company` | Every order of their company (head trader, compliance, ops) |

Viewing and acting stay separate (`orders.act.*`). Nothing ever crosses companies.

### 7.4 Reaching brokers

* **Direct**: a session owned by one customer company, with that company's CompIDs, to one broker.
* **Hub** (NYFIX, Autex): SOSUV holds one hub connection shared by many customers. On each order we set **115 = the customer's identifier on that hub** and **128 = the target broker**; the user tag (e.g. 116 or 50) comes from the logged-in user and is locked in the template.
* Replies are matched by the order chain: ClOrdIDs are generated by SOFIX and unique across the deployment, so an ER always maps back to exactly one company. A reply that matches no order goes to a platform queue, never to a customer.
* Raw messages of a shared hub session are visible to platform ops only; each customer sees only the messages of its own orders.

### 7.5 Outline impact

* Keep a `TenantId` on `OwnedResource` and on order/message records from the outline (single default tenant), plus `TenantContextProvider` (default: the single owner tenant). This is the only tenancy work needed now; everything else above is buy-side layer work, later.
