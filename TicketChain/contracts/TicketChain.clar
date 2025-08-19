;; Blockchain Ticketing System
;; A secure smart contract for event and travel ticket management with NFT-based tickets,
;; dynamic pricing, transfer capabilities, and comprehensive validation mechanisms

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-insufficient-payment (err u102))
(define-constant err-sold-out (err u103))
(define-constant err-not-ticket-owner (err u104))
(define-constant err-event-not-active (err u105))
(define-constant err-transfer-failed (err u106))
(define-constant err-invalid-price (err u107))
(define-constant err-event-expired (err u108))
(define-constant platform-fee-percentage u5) ;; 5% platform fee

;; Data Maps and Variables
;; Core event information storage
(define-map events
  { event-id: uint }
  {
    name: (string-ascii 100),
    description: (string-ascii 500),
    venue: (string-ascii 200),
    event-date: uint,
    total-tickets: uint,
    available-tickets: uint,
    base-price: uint,
    creator: principal,
    active: bool,
    event-type: (string-ascii 20) ;; "concert", "travel", "sports", etc.
  }
)

;; Individual ticket ownership and metadata
(define-map tickets
  { ticket-id: uint }
  {
    event-id: uint,
    owner: principal,
    price-paid: uint,
    purchase-date: uint,
    used: bool,
    transferable: bool,
    seat-info: (string-ascii 50)
  }
)

;; Track user balances for refunds and payments
(define-map user-balances
  { user: principal }
  { balance: uint }
)

;; Global counters for unique IDs
(define-data-var next-event-id uint u1)
(define-data-var next-ticket-id uint u1)
(define-data-var total-platform-revenue uint u0)

;; Private Functions
;; Calculate dynamic pricing based on demand and time
(define-private (calculate-ticket-price (event-id uint))
  (let (
    (event-data (unwrap! (map-get? events { event-id: event-id }) u0))
    (base-price (get base-price event-data))
    (total-tickets (get total-tickets event-data))
    (available-tickets (get available-tickets event-data))
    (demand-multiplier (/ (* (- total-tickets available-tickets) u100) total-tickets))
  )
  ;; Increase price by up to 50% based on demand (sold tickets / total tickets)
  (+ base-price (/ (* base-price demand-multiplier) u200))
  )
)

;; Validate event is still active and not expired
(define-private (is-event-valid (event-id uint))
  (match (map-get? events { event-id: event-id })
    event-data 
    (and 
      (get active event-data)
      (> (get event-date event-data) block-height)
      (> (get available-tickets event-data) u0)
    )
    false
  )
)

;; Process platform fee calculation
(define-private (calculate-platform-fee (amount uint))
  (/ (* amount platform-fee-percentage) u100)
)

;; Public Functions
;; Create a new event with comprehensive validation
(define-public (create-event 
  (name (string-ascii 100))
  (description (string-ascii 500))
  (venue (string-ascii 200))
  (event-date uint)
  (total-tickets uint)
  (base-price uint)
  (event-type (string-ascii 20))
)
  (let ((event-id (var-get next-event-id)))
    (asserts! (> total-tickets u0) err-invalid-price)
    (asserts! (> base-price u0) err-invalid-price)
    (asserts! (> event-date block-height) err-event-expired)
    
    (map-set events
      { event-id: event-id }
      {
        name: name,
        description: description,
        venue: venue,
        event-date: event-date,
        total-tickets: total-tickets,
        available-tickets: total-tickets,
        base-price: base-price,
        creator: tx-sender,
        active: true,
        event-type: event-type
      }
    )
    (var-set next-event-id (+ event-id u1))
    (ok event-id)
  )
)

;; Purchase tickets with dynamic pricing and validation
(define-public (purchase-ticket (event-id uint) (seat-info (string-ascii 50)))
  (let (
    (event-data (unwrap! (map-get? events { event-id: event-id }) err-not-found))
    (current-price (calculate-ticket-price event-id))
    (platform-fee (calculate-platform-fee current-price))
    (total-cost (+ current-price platform-fee))
    (ticket-id (var-get next-ticket-id))
  )
    (asserts! (is-event-valid event-id) err-event-not-active)
    (asserts! (>= (stx-get-balance tx-sender) total-cost) err-insufficient-payment)
    
    ;; Transfer payment
    (try! (stx-transfer? total-cost tx-sender contract-owner))
    
    ;; Create ticket
    (map-set tickets
      { ticket-id: ticket-id }
      {
        event-id: event-id,
        owner: tx-sender,
        price-paid: current-price,
        purchase-date: block-height,
        used: false,
        transferable: true,
        seat-info: seat-info
      }
    )
    
    ;; Update event availability
    (map-set events
      { event-id: event-id }
      (merge event-data { available-tickets: (- (get available-tickets event-data) u1) })
    )
    
    ;; Update platform revenue
    (var-set total-platform-revenue (+ (var-get total-platform-revenue) platform-fee))
    (var-set next-ticket-id (+ ticket-id u1))
    (ok ticket-id)
  )
)

;; Transfer ticket ownership with validation
(define-public (transfer-ticket (ticket-id uint) (new-owner principal))
  (let ((ticket-data (unwrap! (map-get? tickets { ticket-id: ticket-id }) err-not-found)))
    (asserts! (is-eq tx-sender (get owner ticket-data)) err-not-ticket-owner)
    (asserts! (get transferable ticket-data) err-transfer-failed)
    (asserts! (not (get used ticket-data)) err-transfer-failed)
    
    (map-set tickets
      { ticket-id: ticket-id }
      (merge ticket-data { owner: new-owner })
    )
    (ok true)
  )
)

;; Helper function for batch ticket creation
(define-private (create-batch-ticket 
  (seat-info (string-ascii 50))
  (batch-data { event-id: uint, price-paid: uint, current-ticket-id: uint, success: bool })
)
  (if (get success batch-data)
    (begin
      (map-set tickets
        { ticket-id: (get current-ticket-id batch-data) }
        {
          event-id: (get event-id batch-data),
          owner: tx-sender,
          price-paid: (get price-paid batch-data),
          purchase-date: block-height,
          used: false,
          transferable: true,
          seat-info: seat-info
        }
      )
      (merge batch-data { current-ticket-id: (+ (get current-ticket-id batch-data) u1) })
    )
    batch-data
  )
)


