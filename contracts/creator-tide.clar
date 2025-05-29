;; creator-tide.clar
;; CreatorTide: A decentralized milestone-based funding platform for creative projects
;; This contract manages the full lifecycle of creator projects including registration,
;; funding, milestone verification, and fund distribution. It implements a staged release
;; funding mechanism with verification through either community voting or trusted reviewers.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-PROJECT-EXISTS (err u101))
(define-constant ERR-PROJECT-NOT-FOUND (err u102))
(define-constant ERR-INVALID-PARAMETERS (err u103))
(define-constant ERR-FUNDING-ACTIVE (err u104))
(define-constant ERR-FUNDING-INACTIVE (err u105))
(define-constant ERR-INSUFFICIENT-FUNDING (err u106))
(define-constant ERR-MILESTONE-NOT-FOUND (err u107))
(define-constant ERR-MILESTONE-NOT-APPROVED (err u108))
(define-constant ERR-ALREADY-BACKED (err u109))
(define-constant ERR-ALREADY-VOTED (err u110))
(define-constant ERR-MILESTONE-NOT-ACTIVE (err u111))
(define-constant ERR-MILESTONE-ALREADY-APPROVED (err u112))
(define-constant ERR-NOT-MILESTONE-REVIEWER (err u113))
(define-constant ERR-REFUND-NOT-AVAILABLE (err u114))
(define-constant ERR-TRANSFER-FAILED (err u115))
(define-constant ERR-DEADLINE-PASSED (err u116))
(define-constant ERR-DEADLINE-NOT-PASSED (err u117))
(define-constant ERR-INVALID-REVIEWER-SETUP (err u118))

;; Project status enumeration
(define-constant STATUS-DRAFT u0)      ;; Project created but not yet open for funding
(define-constant STATUS-FUNDING u1)    ;; Project actively accepting funding
(define-constant STATUS-ACTIVE u2)     ;; Project funded and in progress
(define-constant STATUS-COMPLETED u3)  ;; Project successfully completed
(define-constant STATUS-CANCELLED u4)  ;; Project cancelled

;; Verification type enumeration
(define-constant VERIFICATION-VOTING u0)   ;; Milestones verified by backer voting
(define-constant VERIFICATION-REVIEWER u1) ;; Milestones verified by designated reviewers

;; Platform fee percentage (0.5% = 5 / 1000)
(define-constant PLATFORM-FEE-PERCENTAGE u5)
(define-constant PLATFORM-FEE-DENOMINATOR u1000)

;; Platform treasury address
(define-constant PLATFORM-TREASURY tx-sender)

;; Data Maps

;; Projects data
(define-map projects
  { project-id: uint }
  {
    creator: principal,
    title: (string-ascii 100),
    description: (string-utf8 1000),
    funding-goal: uint,
    current-funding: uint,
    status: uint,
    verification-type: uint,
    funding-deadline: uint,
    milestone-count: uint,
    next-milestone-index: uint
  }
)

;; Milestones for each project
(define-map milestones
  { project-id: uint, milestone-index: uint }
  {
    title: (string-ascii 100),
    description: (string-utf8 500),
    percentage: uint,
    deadline: uint,
    status: uint,        ;; 0: pending, 1: active, 2: completed, 3: failed
    approval-count: uint,
    rejection-count: uint,
    funds-released: bool
  }
)

;; Project reviewers (only used when verification-type is VERIFICATION-REVIEWER)
(define-map project-reviewers
  { project-id: uint, reviewer: principal }
  { active: bool }
)

;; Backers data
(define-map backers
  { project-id: uint, backer: principal }
  {
    amount: uint,
    refunded: bool
  }
)

;; Voting records
(define-map milestone-votes
  { project-id: uint, milestone-index: uint, voter: principal }
  { approved: bool }
)

;; Contract data variables
(define-data-var next-project-id uint u1)

;; Private functions

;; Calculate platform fee for a given amount
(define-private (calculate-platform-fee (amount uint))
  (/ (* amount PLATFORM-FEE-PERCENTAGE) PLATFORM-FEE-DENOMINATOR)
)

;; Calculate milestone amount based on percentage of total funding
(define-private (calculate-milestone-amount (total-funding uint) (percentage uint))
  (/ (* total-funding percentage) u100)
)

;; Check if the sender is the project creator
(define-private (is-project-creator (project-id uint))
  (let (
    (project (unwrap! (map-get? projects { project-id: project-id }) false))
  )
    (is-eq (get creator project) tx-sender)
  )
)

;; Check if milestone exists
(define-private (milestone-exists (project-id uint) (milestone-index uint))
  (is-some (map-get? milestones { project-id: project-id, milestone-index: milestone-index }))
)

;; Check if a principal is a reviewer for a project
(define-private (is-project-reviewer (project-id uint) (reviewer principal))
  (match (map-get? project-reviewers { project-id: project-id, reviewer: reviewer })
    reviewer-data (get active reviewer-data)
    false
  )
)

;; Check if a project's funding deadline has passed
(define-private (is-funding-deadline-passed (project-id uint))
  (let (
    (project (unwrap! (map-get? projects { project-id: project-id }) false))
    (current-block-height block-height)
  )
    (>= current-block-height (get funding-deadline project))
  )
)

;; Check if a milestone's deadline has passed
(define-private (is-milestone-deadline-passed (project-id uint) (milestone-index uint))
  (let (
    (milestone (unwrap! (map-get? milestones { project-id: project-id, milestone-index: milestone-index }) false))
    (current-block-height block-height)
  )
    (>= current-block-height (get deadline milestone))
  )
)

;; Public functions

;; Create a new project
(define-public (create-project 
  (title (string-ascii 100))
  (description (string-utf8 1000))
  (funding-goal uint)
  (verification-type uint)
  (funding-deadline uint)
)
  (let (
    (project-id (var-get next-project-id))
  )
    ;; Input validation
    (asserts! (> funding-goal u0) ERR-INVALID-PARAMETERS)
    (asserts! (or (is-eq verification-type VERIFICATION-VOTING) 
                  (is-eq verification-type VERIFICATION-REVIEWER)) ERR-INVALID-PARAMETERS)
    (asserts! (> funding-deadline block-height) ERR-INVALID-PARAMETERS)
    
    ;; Create project
    (map-set projects
      { project-id: project-id }
      {
        creator: tx-sender,
        title: title,
        description: description,
        funding-goal: funding-goal,
        current-funding: u0,
        status: STATUS-DRAFT,
        verification-type: verification-type,
        funding-deadline: funding-deadline,
        milestone-count: u0,
        next-milestone-index: u0
      }
    )
    
    ;; Increment project ID counter
    (var-set next-project-id (+ project-id u1))
    
    (ok project-id)
  )
)

;; Add a milestone to a project
(define-public (add-milestone
  (project-id uint)
  (title (string-ascii 100))
  (description (string-utf8 500))
  (percentage uint)
  (deadline uint)
)
  (let (
    (project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
    (milestone-index (get next-milestone-index project))
  )
    ;; Authorization check
    (asserts! (is-eq (get creator project) tx-sender) ERR-NOT-AUTHORIZED)
    
    ;; Input validation
    (asserts! (is-eq (get status project) STATUS-DRAFT) ERR-FUNDING-ACTIVE)
    (asserts! (> percentage u0) ERR-INVALID-PARAMETERS)
    (asserts! (<= percentage u100) ERR-INVALID-PARAMETERS)
    (asserts! (> deadline block-height) ERR-INVALID-PARAMETERS)
    
    ;; Create milestone
    (map-set milestones
      { project-id: project-id, milestone-index: milestone-index }
      {
        title: title,
        description: description,
        percentage: percentage,
        deadline: deadline,
        status: u0,  ;; Pending
        approval-count: u0,
        rejection-count: u0,
        funds-released: false
      }
    )
    
    ;; Update project with new milestone count
    (map-set projects
      { project-id: project-id }
      (merge project {
        milestone-count: (+ (get milestone-count project) u1),
        next-milestone-index: (+ milestone-index u1)
      })
    )
    
    (ok milestone-index)
  )
)

;; Add a reviewer to a project (only for VERIFICATION-REVIEWER type projects)
(define-public (add-project-reviewer (project-id uint) (reviewer principal))
  (let (
    (project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
  )
    ;; Authorization and validation checks
    (asserts! (is-eq (get creator project) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get verification-type project) VERIFICATION-REVIEWER) ERR-INVALID-REVIEWER-SETUP)
    (asserts! (is-eq (get status project) STATUS-DRAFT) ERR-FUNDING-ACTIVE)
    
    ;; Add reviewer
    (map-set project-reviewers
      { project-id: project-id, reviewer: reviewer }
      { active: true }
    )
    
    (ok true)
  )
)

;; Activate project for funding - transitions from DRAFT to FUNDING
(define-public (activate-project (project-id uint))
  (let (
    (project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
    (milestone-count (get milestone-count project))
  )
    ;; Authorization and validation checks
    (asserts! (is-eq (get creator project) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status project) STATUS-DRAFT) ERR-FUNDING-ACTIVE)
    (asserts! (> milestone-count u0) ERR-INVALID-PARAMETERS)
    
    ;; Check milestone percentages sum to 100%
    ;; Note: In a full implementation, we would verify the sum here
    
    ;; Update project status to funding
    (map-set projects
      { project-id: project-id }
      (merge project { status: STATUS-FUNDING })
    )
    
    (ok true)
  )
)

;; Back a project with STX
(define-public (back-project (project-id uint) (amount uint))
  (let (
    (project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
    (backer-info (map-get? backers { project-id: project-id, backer: tx-sender }))
  )
    ;; Validation checks
    (asserts! (is-eq (get status project) STATUS-FUNDING) ERR-FUNDING-INACTIVE)
    (asserts! (not (is-funding-deadline-passed project-id)) ERR-DEADLINE-PASSED)
    (asserts! (> amount u0) ERR-INVALID-PARAMETERS)
    (asserts! (is-none backer-info) ERR-ALREADY-BACKED)
    
    ;; Transfer funds to contract
    (asserts! (is-ok (stx-transfer? amount tx-sender (as-contract tx-sender))) ERR-TRANSFER-FAILED)
    
    ;; Record backer information
    (map-set backers
      { project-id: project-id, backer: tx-sender }
      { amount: amount, refunded: false }
    )
    
    ;; Update project funding
    (let (
      (new-funding (+ (get current-funding project) amount))
      (funding-goal (get funding-goal project))
      (updated-status (if (>= new-funding funding-goal) STATUS-ACTIVE (get status project)))
    )
      (map-set projects
        { project-id: project-id }
        (merge project {
          current-funding: new-funding,
          status: updated-status
        })
      )
      
      ;; If project just became active, activate the first milestone
      (if (is-eq updated-status STATUS-ACTIVE)
        (map-set milestones
          { project-id: project-id, milestone-index: u0 }
          (merge (unwrap! (map-get? milestones { project-id: project-id, milestone-index: u0 }) ERR-MILESTONE-NOT-FOUND)
            { status: u1 }) ;; Set to Active
        )
        true
      )
      
      (ok true)
    )
  )
)

;; Cancel a project (creator only, only during funding phase)
(define-public (cancel-project (project-id uint))
  (let (
    (project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
  )
    ;; Authorization and validation checks
    (asserts! (is-eq (get creator project) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status project) STATUS-FUNDING) ERR-FUNDING-INACTIVE)
    
    ;; Update project status to cancelled
    (map-set projects
      { project-id: project-id }
      (merge project { status: STATUS-CANCELLED })
    )
    
    (ok true)
  )
)

;; Submit milestone for verification (creator only)
(define-public (submit-milestone-for-verification (project-id uint) (milestone-index uint))
  (let (
    (project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
    (milestone (unwrap! (map-get? milestones { project-id: project-id, milestone-index: milestone-index }) ERR-MILESTONE-NOT-FOUND))
  )
    ;; Authorization and validation checks
    (asserts! (is-eq (get creator project) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status project) STATUS-ACTIVE) ERR-FUNDING-INACTIVE)
    (asserts! (is-eq (get status milestone) u1) ERR-MILESTONE-NOT-ACTIVE) ;; Must be active
    
    ;; Set milestone to review stage
    (map-set milestones
      { project-id: project-id, milestone-index: milestone-index }
      (merge milestone { status: u2 }) ;; Set to completed/review state
    )
    
    (ok true)
  )
)

;; Vote on milestone completion (for VERIFICATION-VOTING projects)
(define-public (vote-on-milestone (project-id uint) (milestone-index uint) (approve bool))
  (let (
    (project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
    (milestone (unwrap! (map-get? milestones { project-id: project-id, milestone-index: milestone-index }) ERR-MILESTONE-NOT-FOUND))
    (backer-info (unwrap! (map-get? backers { project-id: project-id, backer: tx-sender }) ERR-NOT-AUTHORIZED))
    (vote-record (map-get? milestone-votes { project-id: project-id, milestone-index: milestone-index, voter: tx-sender }))
  )
    ;; Validation checks
    (asserts! (is-eq (get verification-type project) VERIFICATION-VOTING) ERR-INVALID-PARAMETERS)
    (asserts! (is-eq (get status milestone) u2) ERR-MILESTONE-NOT-ACTIVE) ;; Must be in review
    (asserts! (is-none vote-record) ERR-ALREADY-VOTED)
    
    ;; Record vote
    (map-set milestone-votes
      { project-id: project-id, milestone-index: milestone-index, voter: tx-sender }
      { approved: approve }
    )
    
    ;; Update milestone vote counts
    (let (
      (new-approval-count (if approve (+ (get approval-count milestone) u1) (get approval-count milestone)))
      (new-rejection-count (if (not approve) (+ (get rejection-count milestone) u1) (get rejection-count milestone)))
    )
      (map-set milestones
        { project-id: project-id, milestone-index: milestone-index }
        (merge milestone {
          approval-count: new-approval-count,
          rejection-count: new-rejection-count
        })
      )
      
      (ok true)
    )
  )
)

;; Approve milestone (for VERIFICATION-REVIEWER projects)
(define-public (reviewer-approve-milestone (project-id uint) (milestone-index uint))
  (let (
    (project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
    (milestone (unwrap! (map-get? milestones { project-id: project-id, milestone-index: milestone-index }) ERR-MILESTONE-NOT-FOUND))
  )
    ;; Validation checks
    (asserts! (is-eq (get verification-type project) VERIFICATION-REVIEWER) ERR-INVALID-PARAMETERS)
    (asserts! (is-project-reviewer project-id tx-sender) ERR-NOT-MILESTONE-REVIEWER)
    (asserts! (is-eq (get status milestone) u2) ERR-MILESTONE-NOT-ACTIVE) ;; Must be in review
    
    ;; Update milestone to approved
    (map-set milestones
      { project-id: project-id, milestone-index: milestone-index }
      (merge milestone {
        approval-count: (+ (get approval-count milestone) u1)
      })
    )
    
    (ok true)
  )
)

;; Release milestone funds (can be called by anyone after appropriate approvals)
(define-public (release-milestone-funds (project-id uint) (milestone-index uint))
  (let (
    (project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
    (milestone (unwrap! (map-get? milestones { project-id: project-id, milestone-index: milestone-index }) ERR-MILESTONE-NOT-FOUND))
    (creator (get creator project))
    (current-funding (get current-funding project))
  )
    ;; Validation checks
    (asserts! (not (get funds-released milestone)) ERR-MILESTONE-ALREADY-APPROVED)
    (asserts! (is-eq (get status milestone) u2) ERR-MILESTONE-NOT-ACTIVE) ;; Must be in review
    
    ;; Check if milestone is approved
    (asserts!
      (if (is-eq (get verification-type project) VERIFICATION-VOTING)
        ;; For voting, need majority approval from backers
        (> (get approval-count milestone) (get rejection-count milestone))
        ;; For reviewer, just need one approval
        (> (get approval-count milestone) u0)
      )
      ERR-MILESTONE-NOT-APPROVED
    )
    
    ;; Calculate amounts
    (let (
      (milestone-amount (calculate-milestone-amount current-funding (get percentage milestone)))
      (platform-fee (calculate-platform-fee milestone-amount))
      (creator-amount (- milestone-amount platform-fee))
      (next-milestone-index (+ milestone-index u1))
      (next-milestone-exists (milestone-exists project-id next-milestone-index))
    )
      ;; Mark milestone as funds released
      (map-set milestones
        { project-id: project-id, milestone-index: milestone-index }
        (merge milestone { funds-released: true })
      )
      
      ;; Transfer funds to creator
      (asserts! (is-ok (as-contract (stx-transfer? creator-amount creator tx-sender))) ERR-TRANSFER-FAILED)
      
      ;; Transfer platform fee
      (asserts! (is-ok (as-contract (stx-transfer? platform-fee PLATFORM-TREASURY tx-sender))) ERR-TRANSFER-FAILED)
      
      ;; If next milestone exists, activate it
      (if next-milestone-exists
        (map-set milestones
          { project-id: project-id, milestone-index: next-milestone-index }
          (merge (unwrap! (map-get? milestones { project-id: project-id, milestone-index: next-milestone-index }) ERR-MILESTONE-NOT-FOUND)
            { status: u1 }) ;; Set to Active
        )
        ;; If no next milestone, mark project as completed
        (map-set projects
          { project-id: project-id }
          (merge project { status: STATUS-COMPLETED })
        )
      )
      
      (ok true)
    )
  )
)

;; Report milestone failure (can be called after deadline has passed without completion)
(define-public (report-milestone-failure (project-id uint) (milestone-index uint))
  (let (
    (project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
    (milestone (unwrap! (map-get? milestones { project-id: project-id, milestone-index: milestone-index }) ERR-MILESTONE-NOT-FOUND))
  )
    ;; Validation checks
    (asserts! (is-eq (get status milestone) u1) ERR-MILESTONE-NOT-ACTIVE) ;; Must be active
    (asserts! (is-milestone-deadline-passed project-id milestone-index) ERR-DEADLINE-NOT-PASSED)
    
    ;; Mark milestone as failed
    (map-set milestones
      { project-id: project-id, milestone-index: milestone-index }
      (merge milestone { status: u3 }) ;; Set to failed
    )
    
    ;; Mark project as cancelled
    (map-set projects
      { project-id: project-id }
      (merge project { status: STATUS-CANCELLED })
    )
    
    (ok true)
  )
)

;; Read-only functions

;; Get project details
(define-read-only (get-project (project-id uint))
  (map-get? projects { project-id: project-id })
)

;; Get milestone details
(define-read-only (get-milestone (project-id uint) (milestone-index uint))
  (map-get? milestones { project-id: project-id, milestone-index: milestone-index })
)

;; Get backer info
(define-read-only (get-backer-info (project-id uint) (backer principal))
  (map-get? backers { project-id: project-id, backer: backer })
)

;; Check if principal is a reviewer
(define-read-only (get-reviewer-status (project-id uint) (reviewer principal))
  (map-get? project-reviewers { project-id: project-id, reviewer: reviewer })
)

;; Get total project milestone count
(define-read-only (get-milestone-count (project-id uint))
  (match (map-get? projects { project-id: project-id })
    project (get milestone-count project)
    u0
  )
)