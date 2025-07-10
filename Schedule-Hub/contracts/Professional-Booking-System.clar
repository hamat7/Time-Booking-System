;; Professional Appointment Booking and Payment Management System Smart Contract
;; A comprehensive blockchain-based appointment scheduling platform that facilitates
;; secure booking, payment processing, and lifecycle management for professional services.
;; Features include automated deposit handling, conflict-free scheduling, flexible 
;; rescheduling, and intelligent refund processing with time-based penalties.

;; Contract administrator and system state
(define-data-var contract-owner principal tx-sender)
(define-data-var appointment-counter uint u1)

;; System Error Codes
(define-constant ERR-UNAUTHORIZED-USER (err u100))
(define-constant ERR-INVALID-APPOINTMENT-TIME (err u101))
(define-constant ERR-SLOT-NOT-AVAILABLE (err u102))
(define-constant ERR-APPOINTMENT-NOT-FOUND (err u103))
(define-constant ERR-INVALID-STATUS-TRANSITION (err u104))
(define-constant ERR-DUPLICATE-BOOKING (err u105))
(define-constant ERR-INSUFFICIENT-FUNDS (err u106))
(define-constant ERR-REFUND-FAILED (err u107))
(define-constant ERR-PAYMENT-FAILED (err u108))
(define-constant ERR-DEADLINE-EXPIRED (err u109))
(define-constant ERR-INVALID-PRICE (err u110))
(define-constant ERR-INVALID-SERVICE-TYPE (err u111))
(define-constant ERR-INVALID-APPOINTMENT-ID (err u112))

;; Business Logic Constants
(define-constant minimum-advance-notice-hours u12)
(define-constant full-refund-deadline-hours u24)
(define-constant seconds-per-hour u3600)
(define-constant partial-refund-percentage u50)
(define-constant deposit-percentage u50)
(define-constant maximum-appointments-per-user u100)

;; Core Data Structures

;; Main appointment record with comprehensive booking details
(define-map appointment-records
  { appointment-id: uint }
  {
    provider-address: principal,
    client-address: principal,
    appointment-timestamp: uint,
    duration-in-minutes: uint,
    current-status: (string-ascii 20),
    service-type: (string-ascii 50),
    total-fee: uint,
    deposit-paid: uint,
    payment-status: (string-ascii 20)
  }
)

;; Provider's appointment management registry
(define-map provider-appointments
  { provider-address: principal }
  { appointment-list: (list 100 uint) }
)

;; Client's booking history and active appointments
(define-map client-bookings
  { client-address: principal }
  { booking-list: (list 100 uint) }
)

;; Service pricing structure by provider and service type
(define-map service-rates
  { provider-address: principal, service-type: (string-ascii 50) }
  { price-in-microstx: uint }
)

;; Input Validation Functions

(define-private (is-valid-service-type (service-type (string-ascii 50)))
  (and 
    (> (len service-type) u0)
    (<= (len service-type) u50)
  )
)

(define-private (is-valid-appointment-id (appointment-id uint))
  (and 
    (> appointment-id u0) 
    (< appointment-id (var-get appointment-counter))
  )
)

(define-private (is-future-timestamp (timestamp uint))
  (> timestamp (unwrap-panic (get-block-info? time (- block-height u1))))
)

(define-private (is-positive-amount (amount uint))
  (> amount u0)
)

;; Time Management and Scheduling Functions

(define-read-only (get-current-time)
  (unwrap-panic (get-block-info? time (- block-height u1)))
)

(define-private (calculate-appointment-end-time (start-time uint) (duration-minutes uint))
  (+ start-time (* duration-minutes u60))
)

(define-private (check-time-overlap (existing-start uint) (existing-end uint) (new-start uint) (new-end uint))
  (not (or (< new-end existing-start) (> new-start existing-end)))
)

(define-private (validate-appointment-slot 
  (existing-appointment-id uint) 
  (availability-check { 
    is-available: bool, 
    requested-start: uint, 
    requested-end: uint 
  })
)
  (if (not (get is-available availability-check))
    availability-check
    (let (
      (appointment-data (unwrap-panic (map-get? appointment-records { appointment-id: existing-appointment-id })))
      (existing-start (get appointment-timestamp appointment-data))
      (existing-duration (get duration-in-minutes appointment-data))
      (existing-end (calculate-appointment-end-time existing-start existing-duration))
      (appointment-status (get current-status appointment-data))
      (new-start (get requested-start availability-check))
      (new-end (get requested-end availability-check))
    )
      (if (or (is-eq appointment-status "cancelled") (is-eq appointment-status "completed"))
        availability-check
        (merge availability-check { 
          is-available: (not (check-time-overlap existing-start existing-end new-start new-end))
        })
      )
    )
  )
)

(define-read-only (check-provider-schedule-availability 
  (provider-address principal) 
  (requested-start-time uint) 
  (session-duration-minutes uint)
)
  (let (
    (provider-schedule (default-to 
      { appointment-list: (list) } 
      (map-get? provider-appointments { provider-address: provider-address })
    ))
    (requested-end-time (calculate-appointment-end-time requested-start-time session-duration-minutes))
    (initial-check { 
      is-available: true, 
      requested-start: requested-start-time, 
      requested-end: requested-end-time 
    })
    (final-result (fold 
      validate-appointment-slot 
      (get appointment-list provider-schedule) 
      initial-check
    ))
  )
    (get is-available final-result)
  )
)

;; Data Retrieval Functions

(define-read-only (get-appointment-information (appointment-id uint))
  (match (map-get? appointment-records { appointment-id: appointment-id })
    appointment-data (ok appointment-data)
    ERR-APPOINTMENT-NOT-FOUND
  )
)

(define-read-only (get-service-pricing 
  (provider-address principal) 
  (service-type (string-ascii 50))
)
  (default-to 
    { price-in-microstx: u0 } 
    (map-get? service-rates { 
      provider-address: provider-address, 
      service-type: service-type 
    })
  )
)

(define-read-only (get-provider-schedule (provider-address principal))
  (match (map-get? provider-appointments { provider-address: provider-address })
    provider-data (ok (get appointment-list provider-data))
    (ok (list))
  )
)

(define-read-only (get-client-booking-history (client-address principal))
  (match (map-get? client-bookings { client-address: client-address })
    client-data (ok (get booking-list client-data))
    (ok (list))
  )
)

;; Registry Management Helper Functions

(define-private (register-appointment-with-provider 
  (provider-address principal) 
  (appointment-id uint)
)
  (let (
    (current-provider-data (default-to 
      { appointment-list: (list) } 
      (map-get? provider-appointments { provider-address: provider-address })
    ))
    (updated-list (unwrap-panic 
      (as-max-len? 
        (append (get appointment-list current-provider-data) appointment-id) 
        u100
      )
    ))
  )
    (map-set provider-appointments
      { provider-address: provider-address }
      { appointment-list: updated-list }
    )
  )
)

(define-private (register-booking-with-client 
  (client-address principal) 
  (appointment-id uint)
)
  (let (
    (current-client-data (default-to 
      { booking-list: (list) } 
      (map-get? client-bookings { client-address: client-address })
    ))
    (updated-list (unwrap-panic 
      (as-max-len? 
        (append (get booking-list current-client-data) appointment-id) 
        u100
      )
    ))
  )
    (map-set client-bookings
      { client-address: client-address }
      { booking-list: updated-list }
    )
  )
)

;; Service Configuration Management

(define-public (set-service-pricing 
  (service-type (string-ascii 50)) 
  (price-in-microstx uint)
)
  (begin
    (asserts! (is-positive-amount price-in-microstx) ERR-INVALID-PRICE)
    (asserts! (is-valid-service-type service-type) ERR-INVALID-SERVICE-TYPE)
    (ok (map-set service-rates
      { provider-address: tx-sender, service-type: service-type }
      { price-in-microstx: price-in-microstx }
    ))
  )
)

;; Core Appointment Booking System

(define-public (book-appointment 
  (provider-address principal) 
  (appointment-timestamp uint) 
  (duration-in-minutes uint) 
  (service-type (string-ascii 50))
)
  (begin
    (asserts! (is-valid-service-type service-type) ERR-INVALID-SERVICE-TYPE)
    
    (let (
      (client-address tx-sender)
      (new-appointment-id (var-get appointment-counter))
      (pricing-info (get-service-pricing provider-address service-type))
      (total-service-fee (get price-in-microstx pricing-info))
      (required-deposit (/ total-service-fee u2))
      (current-time (get-current-time))
    )
        
      (asserts! (is-future-timestamp appointment-timestamp) ERR-INVALID-APPOINTMENT-TIME)
      (asserts! (is-positive-amount total-service-fee) ERR-INVALID-PRICE)
      (asserts! (check-provider-schedule-availability provider-address appointment-timestamp duration-in-minutes) ERR-SLOT-NOT-AVAILABLE)
      
      (asserts! (is-ok (stx-transfer? required-deposit tx-sender provider-address)) ERR-PAYMENT-FAILED)
          
      (var-set appointment-counter (+ new-appointment-id u1))
      
      (map-set appointment-records
        { appointment-id: new-appointment-id }
        {
          provider-address: provider-address,
          client-address: client-address,
          appointment-timestamp: appointment-timestamp,
          duration-in-minutes: duration-in-minutes,
          current-status: "confirmed",
          service-type: service-type,
          total-fee: total-service-fee,
          deposit-paid: required-deposit,
          payment-status: "deposit-received"
        }
      )
      
      (register-appointment-with-provider provider-address new-appointment-id)
      (register-booking-with-client client-address new-appointment-id)
      
      (ok new-appointment-id)
    )
  )
)

;; Payment Processing System

(define-public (complete-appointment-payment (appointment-id uint))
  (begin
    (asserts! (is-valid-appointment-id appointment-id) ERR-INVALID-APPOINTMENT-ID)
    
    (let (
      (appointment-data (unwrap! (map-get? appointment-records { appointment-id: appointment-id }) ERR-APPOINTMENT-NOT-FOUND))
      (client-address (get client-address appointment-data))
      (provider-address (get provider-address appointment-data))
      (total-cost (get total-fee appointment-data))
      (deposit-amount (get deposit-paid appointment-data))
      (appointment-status (get current-status appointment-data))
      (remaining-balance (- total-cost deposit-amount))
    )
      (asserts! (is-eq tx-sender client-address) ERR-UNAUTHORIZED-USER)
      (asserts! (is-eq appointment-status "confirmed") ERR-INVALID-STATUS-TRANSITION)
      
      (asserts! (is-ok (stx-transfer? remaining-balance tx-sender provider-address)) ERR-PAYMENT-FAILED)
      
      (map-set appointment-records
        { appointment-id: appointment-id }
        (merge appointment-data { payment-status: "fully-paid" })
      )
      
      (ok true)
    )
  )
)

;; Appointment Lifecycle Management

(define-public (cancel-appointment (appointment-id uint))
  (begin
    (asserts! (is-valid-appointment-id appointment-id) ERR-INVALID-APPOINTMENT-ID)
    
    (let (
      (appointment-data (unwrap! (map-get? appointment-records { appointment-id: appointment-id }) ERR-APPOINTMENT-NOT-FOUND))
      (provider-address (get provider-address appointment-data))
      (client-address (get client-address appointment-data))
      (appointment-status (get current-status appointment-data))
    )
      (asserts! (or (is-eq appointment-status "confirmed") (is-eq appointment-status "rescheduled")) ERR-INVALID-STATUS-TRANSITION)
      (asserts! (or (is-eq tx-sender client-address) (is-eq tx-sender provider-address)) ERR-UNAUTHORIZED-USER)
      
      (ok (map-set appointment-records
        { appointment-id: appointment-id }
        (merge appointment-data { current-status: "cancelled" })
      ))
    )
  )
)

(define-public (process-refund (appointment-id uint))
  (begin
    (asserts! (is-valid-appointment-id appointment-id) ERR-INVALID-APPOINTMENT-ID)
    
    (let (
      (appointment-data (unwrap! (map-get? appointment-records { appointment-id: appointment-id }) ERR-APPOINTMENT-NOT-FOUND))
      (client-address (get client-address appointment-data))
      (provider-address (get provider-address appointment-data))
      (deposit-amount (get deposit-paid appointment-data))
      (appointment-status (get current-status appointment-data))
      (current-time (get-current-time))
      (appointment-time (get appointment-timestamp appointment-data))
      (hours-until-appointment (/ (- appointment-time current-time) seconds-per-hour))
      (refund-amount (if (>= hours-until-appointment full-refund-deadline-hours)
                        deposit-amount
                        (/ (* deposit-amount partial-refund-percentage) u100)))
    )
      (asserts! (is-eq tx-sender provider-address) ERR-UNAUTHORIZED-USER)
      (asserts! (is-eq appointment-status "cancelled") ERR-INVALID-STATUS-TRANSITION)
      
      (asserts! (is-ok (stx-transfer? refund-amount tx-sender client-address)) ERR-REFUND-FAILED)
      
      (map-set appointment-records
        { appointment-id: appointment-id }
        (merge appointment-data { payment-status: "refund-processed" })
      )
      
      (ok true)
    )
  )
)

(define-public (mark-appointment-complete (appointment-id uint))
  (begin
    (asserts! (is-valid-appointment-id appointment-id) ERR-INVALID-APPOINTMENT-ID)
    
    (let (
      (appointment-data (unwrap! (map-get? appointment-records { appointment-id: appointment-id }) ERR-APPOINTMENT-NOT-FOUND))
      (provider-address (get provider-address appointment-data))
      (client-address (get client-address appointment-data))
      (appointment-status (get current-status appointment-data))
      (payment-status (get payment-status appointment-data))
      (total-cost (get total-fee appointment-data))
      (deposit-amount (get deposit-paid appointment-data))
      (remaining-payment (- total-cost deposit-amount))
    )
      (asserts! (or (is-eq appointment-status "confirmed") (is-eq appointment-status "rescheduled")) ERR-INVALID-STATUS-TRANSITION)
      (asserts! (is-eq tx-sender provider-address) ERR-UNAUTHORIZED-USER)
      
      (if (and (> remaining-payment u0) (is-eq payment-status "deposit-received"))
        (match (stx-transfer? remaining-payment client-address provider-address)
          success (begin
            (map-set appointment-records
              { appointment-id: appointment-id }
              (merge appointment-data { 
                current-status: "completed",
                payment-status: "fully-paid" 
              })
            )
            (ok true)
          )
          error (begin
            (map-set appointment-records
              { appointment-id: appointment-id }
              (merge appointment-data { current-status: "completed" })
            )
            (ok true)
          )
        )
        (begin
          (map-set appointment-records
            { appointment-id: appointment-id }
            (merge appointment-data { current-status: "completed" })
          )
          (ok true)
        )
      )
    )
  )
)

;; Appointment Modification Functions

(define-public (reschedule-appointment (appointment-id uint) (new-appointment-timestamp uint))
  (begin
    (asserts! (is-valid-appointment-id appointment-id) ERR-INVALID-APPOINTMENT-ID)
    
    (let (
      (appointment-data (unwrap! (map-get? appointment-records { appointment-id: appointment-id }) ERR-APPOINTMENT-NOT-FOUND))
      (provider-address (get provider-address appointment-data))
      (client-address (get client-address appointment-data))
      (current-timestamp (get appointment-timestamp appointment-data))
      (session-duration (get duration-in-minutes appointment-data))
      (appointment-status (get current-status appointment-data))
      (current-time (get-current-time))
      (hours-until-appointment (/ (- current-timestamp current-time) seconds-per-hour))
    )
      (asserts! (is-eq appointment-status "confirmed") ERR-INVALID-STATUS-TRANSITION)
      (asserts! (is-eq tx-sender client-address) ERR-UNAUTHORIZED-USER)
      (asserts! (is-future-timestamp new-appointment-timestamp) ERR-INVALID-APPOINTMENT-TIME)
      (asserts! (>= hours-until-appointment minimum-advance-notice-hours) ERR-DEADLINE-EXPIRED)
      (asserts! (check-provider-schedule-availability provider-address new-appointment-timestamp session-duration) ERR-SLOT-NOT-AVAILABLE)
      
      (ok (map-set appointment-records
        { appointment-id: appointment-id }
        (merge appointment-data { 
          appointment-timestamp: new-appointment-timestamp, 
          current-status: "rescheduled" 
        })
      ))
    )
  )
)

(define-public (modify-appointment-details 
  (appointment-id uint) 
  (new-duration-minutes (optional uint))
  (new-service-type (optional (string-ascii 50)))
)
  (begin
    (asserts! (is-valid-appointment-id appointment-id) ERR-INVALID-APPOINTMENT-ID)
    
    (asserts! (or (is-none new-service-type) 
                  (is-valid-service-type (unwrap! new-service-type ERR-INVALID-SERVICE-TYPE))) 
              ERR-INVALID-SERVICE-TYPE)
    
    (let (
      (appointment-data (unwrap! (map-get? appointment-records { appointment-id: appointment-id }) ERR-APPOINTMENT-NOT-FOUND))
      (provider-address (get provider-address appointment-data))
      (client-address (get client-address appointment-data))
      (current-timestamp (get appointment-timestamp appointment-data))
      (current-duration (get duration-in-minutes appointment-data))
      (current-service (get service-type appointment-data))
      (current-cost (get total-fee appointment-data))
      (current-deposit (get deposit-paid appointment-data))
      (appointment-status (get current-status appointment-data))
      (current-time (get-current-time))
      (hours-until-appointment (/ (- current-timestamp current-time) seconds-per-hour))
      
      (final-duration (default-to current-duration new-duration-minutes))
      (final-service (default-to current-service new-service-type))
      
      (updated-cost (if (is-some new-service-type)
                      (get price-in-microstx (get-service-pricing provider-address (unwrap! new-service-type ERR-INVALID-SERVICE-TYPE)))
                      current-cost))
      
      (cost-adjustment (- updated-cost current-cost))
    )
      (asserts! (is-eq appointment-status "confirmed") ERR-INVALID-STATUS-TRANSITION)
      (asserts! (is-eq tx-sender client-address) ERR-UNAUTHORIZED-USER)
      (asserts! (>= hours-until-appointment minimum-advance-notice-hours) ERR-DEADLINE-EXPIRED)
      
      (asserts! (or (is-eq final-duration current-duration) 
                   (check-provider-schedule-availability provider-address current-timestamp final-duration)) 
                ERR-SLOT-NOT-AVAILABLE)
      
      (if (> cost-adjustment u0)
        (begin
          (asserts! (is-ok (stx-transfer? (/ cost-adjustment u2) tx-sender provider-address)) ERR-PAYMENT-FAILED)
          
          (map-set appointment-records
            { appointment-id: appointment-id }
            (merge appointment-data { 
              duration-in-minutes: final-duration, 
              service-type: final-service,
              total-fee: updated-cost,
              deposit-paid: (+ current-deposit (/ cost-adjustment u2))
            })
          )
          (ok true)
        )
        (begin
          (map-set appointment-records
            { appointment-id: appointment-id }
            (merge appointment-data { 
              duration-in-minutes: final-duration, 
              service-type: final-service,
              total-fee: updated-cost
            })
          )
          (ok true)
        )
      )
    )
  )
)

;; System Administration

(define-public (initialize-booking-system)
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-UNAUTHORIZED-USER)
    (ok true)
  )
)