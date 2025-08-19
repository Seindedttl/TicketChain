# TicketChain

A secure, NFT-based smart contract system for managing event and travel tickets on the Stacks blockchain. TicketChain ensures transparent pricing, safe ownership transfers, batch purchases with discounts, and robust validation.

---

## Overview

TicketChain implements a practical, production-oriented ticketing flow in **Clarity**, featuring:

* **Event registry** with supply, base pricing, and lifecycle controls
* **Dynamic pricing** that increases as tickets sell out (up to +50%)
* **Single and batch purchases**, with optional **group discounts**
* **Ownership transfers** with checks against used/locked tickets
* **Platform fee** accrual for sustainability and transparent revenue tracking

---

## Data Model

### Maps

* **`events`** `{ event-id: uint } → { name, description, venue, event-date, total-tickets, available-tickets, base-price, creator, active, event-type }`
* **`tickets`** `{ ticket-id: uint } → { event-id, owner, price-paid, purchase-date, used, transferable, seat-info }`
* **`user-balances`** `{ user: principal } → { balance: uint }` *(reserved for future refunds/credits)*

### Data Vars

* **`next-event-id : uint`** (starts at `u1`)
* **`next-ticket-id : uint`** (starts at `u1`)
* **`total-platform-revenue : uint`**

### Constants

* **`platform-fee-percentage = u5`** (5%)
* **Error codes**: `u100` owner-only, `u101` not-found, `u102` insufficient-payment, `u103` sold-out, `u104` not-ticket-owner, `u105` event-not-active, `u106` transfer-failed, `u107` invalid-price, `u108` event-expired

> **Implementation note**: The contract defines `(define-constant contract-owner tx-sender)`. In Clarity, using `tx-sender` as a constant may not behave as intended (it refers to the caller at runtime). For a stable treasury/owner, prefer a **`define-data-var owner principal`** set at deploy-time via an initializer or a fixed principal literal.

---

## Public Function Reference

### 1) `create-event`

**Signature**

```clarity
(define-public (create-event 
  (name (string-ascii 100))
  (description (string-ascii 500))
  (venue (string-ascii 200))
  (event-date uint)
  (total-tickets uint)
  (base-price uint)
  (event-type (string-ascii 20))
))
```

**Purpose**: Registers a new event with supply and pricing metadata.

**Parameters**

* `name`, `description`, `venue`: Metadata strings
* `event-date`: Future block height when the event occurs
* `total-tickets`: Total supply (must be > 0)
* `base-price`: Base price in microSTX (must be > 0)
* `event-type`: e.g., `"concert"`, `"travel"`, `"sports"`

**Preconditions**

* `total-tickets > 0` → else `err u107`
* `base-price > 0` → else `err u107`
* `event-date > block-height` → else `err u108`

**State Changes**

* Inserts into `events`
* Sets `available-tickets = total-tickets`
* Increments `next-event-id`

**Returns**

* `(ok event-id)` on success
* `err` on failure (see error codes)

---

### 2) `purchase-ticket`

**Signature**

```clarity
(define-public (purchase-ticket (event-id uint) (seat-info (string-ascii 50))))
```

**Purpose**: Purchases a single ticket with **dynamic pricing**.

**Pricing**

* Uses `calculate-ticket-price(event-id)`
* Adds platform fee: `fee = amount * 5%`

**Preconditions**

* Event exists → else `err u101`
* `is-event-valid(event-id)` → else `err u105`
* Buyer has sufficient STX for `price + fee` → else `err u102`

**State Changes**

* Transfers `total-cost` from buyer to **contract owner** *(see implementation note on owner)*
* Mints one ticket entry in `tickets`
* Decrements `available-tickets` for the event
* Increments `total-platform-revenue` by `fee`
* Increments `next-ticket-id`

**Returns**

* `(ok ticket-id)` on success

**Errors**

* `u101`, `u102`, `u103` (via availability), `u105`

---

### 3) `transfer-ticket`

**Signature**

```clarity
(define-public (transfer-ticket (ticket-id uint) (new-owner principal)))
```

**Purpose**: Transfers ownership of a specific ticket.

**Preconditions**

* Ticket exists → else `err u101`
* Caller is the current `owner` → else `err u104`
* `transferable == true` and `used == false` → else `err u106`

**State Changes**

* Updates `owner` for the given `ticket-id`

**Returns**

* `(ok true)` on success

**Errors**

* `u101`, `u104`, `u106`

---

### 4) `batch-purchase-tickets`

**Signature**

```clarity
(define-public (batch-purchase-tickets 
  (event-id uint)
  (quantity uint)
  (seat-infos (list 10 (string-ascii 50)))
  (apply-group-discount bool)
))
```

**Purpose**: Purchases multiple tickets in one transaction with tiered discounts.

**Discount Tiers**

* If `apply-group-discount == true`:

  * `quantity ≥ 10` → **15%** discount
  * `5 ≤ quantity ≤ 9` → **10%** discount

**Preconditions**

* Event exists & valid → else `err u101` / `err u105`
* `available-tickets ≥ quantity` → else `err u103`
* `quantity ≤ 10` → else `err u107`
* `len(seat-infos) == quantity` → else `err u107`
* Buyer balance covers `discounted-total + fee` → else `err u102`

**State Changes**

* Transfers `total-cost` from buyer to **contract owner** *(see note)*
* Creates `quantity` ticket entries via `create-batch-ticket`
* Decrements `available-tickets` by `quantity`
* Increments `total-platform-revenue` by computed fee
* Increments `next-ticket-id` by `quantity`

**Returns**

```clarity
(ok {
  starting-ticket-id: uint,
  quantity: uint,
  total-paid: uint,
  discount-applied: uint
})
```

> **Implementation caveat**: As written, the function returns the **post-mint counter** in `starting-ticket-id` (i.e., the next id *after* minting). If you need the first minted id, capture `next-ticket-id` in a local before the fold and return that value.

**Errors**

* `u101`, `u102`, `u103`, `u105`, `u107`

---

## Private Function Reference

> Private functions are not callable externally but are critical to pricing and validation logic.

### A) `calculate-ticket-price`

**Signature**

```clarity
(define-private (calculate-ticket-price (event-id uint)))
```

**Purpose**: Computes **dynamic price** using current demand.

**Logic**

* `demand-multiplier = ((sold * 100) / total)`
* Price uplift = `base-price * demand-multiplier / 200` → max **+50%** at 100% sold (approaching sellout)
* `price = base-price + uplift`

**Returns**

* `uint` price (microSTX)

**Errors**

* Uses `(unwrap! (map-get? events ...))` with `u0` in code; consider harmonizing to `err u101` for consistency.

---

### B) `is-event-valid`

**Signature**

```clarity
(define-private (is-event-valid (event-id uint)))
```

**Purpose**: Validates event status prior to sales.

**Checks**

* `active == true`
* `event-date > block-height`
* `available-tickets > 0`

**Returns**

* `bool`

---

### C) `calculate-platform-fee`

**Signature**

```clarity
(define-private (calculate-platform-fee (amount uint)))
```

**Purpose**: Calculates platform fee as **5%** of the amount.

**Returns**

* `uint` (microSTX)

---

### D) `create-batch-ticket`

**Signature**

```clarity
(define-private (create-batch-ticket 
  (seat-info (string-ascii 50))
  (batch-data { event-id: uint, price-paid: uint, current-ticket-id: uint, success: bool })
))
```

**Purpose**: Helper used by `batch-purchase-tickets` to mint each ticket.

**Behavior**

* Writes `tickets[ticket-id]` for current counter
* Increments `current-ticket-id` and returns updated accumulator

**Returns**

* Updated accumulator tuple

---

## Access Control & Treasury

* **Platform fee recipient**: The contract uses `contract-owner` for fee and payment routing. Ensure this is a stable treasury principal.
* **Recommended improvement**: Replace `define-constant contract-owner tx-sender` with:

  ```clarity
  (define-data-var contract-owner principal 'SP...TREASURY)
  ```

  and provide a one-time setter (or immutable literal) at deployment.

---

## Operational Notes

* **Block time vs. real time**: `event-date` uses block height; plan buffers for clock drift.
* **Seat uniqueness**: The current version does **not** enforce a global seat uniqueness map; ensure off-chain seat allocation avoids duplicates.
* **Self-transfer in payments**: If `contract-owner == tx-sender`, `stx-transfer?` becomes a self-transfer. Confirm treasury setup to avoid no-op transfers.

---

## Example Usage (Stacks CLI)

**Create Event**

```bash
clarity-cli call <contract-address> create-event \
  '"Rock Concert"' '"Annual music festival"' '"Stadium"' \
  u123456 u1000 u50000 '"concert"'
```

**Purchase Ticket**

```bash
clarity-cli call <contract-address> purchase-ticket 'u1' '"Section A, Row 5, Seat 12"'
```

**Batch Purchase (5 tickets @ 10% discount)**

```bash
clarity-cli call <contract-address> batch-purchase-tickets \
  'u1' 'u5' '(list "A1" "A2" "A3" "A4" "A5")' 'true'
```

**Transfer Ticket**

```bash
clarity-cli call <contract-address> transfer-ticket 'u10' ''SP2C2J...XG4''
```

---

## License (MIT)

```
MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

---

## Contributing

We welcome contributions from the community. To contribute:

1. **Fork** the repository
2. Create a feature branch: `git checkout -b feat/my-feature`
3. Commit with conventional messages: `feat: add batch discount cap`
4. **Add tests** and update docs
5. Open a **Pull Request** with a clear description and checklist

**PR Checklist**

* [ ] All unit tests pass
* [ ] Gas footprint is reasonable
* [ ] Storage changes are documented
* [ ] Error handling consistent with existing codes

---

## Future Enhancements

* Operator role for venue validation (scan & mark `used`)
* Per-event treasury and split payouts
* Seat uniqueness index `(event-id, seat-id) → ticket-id`
* Refunds & cancellations via `user-balances`
* Merkle allowlists for pre-sales
* Royalty-aware secondary sales entrypoint

---

**TicketChain** — A professional, auditable foundation for blockchain-native ticketing.
