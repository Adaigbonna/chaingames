;; Chain Games - Decentralized Gaming Platform with Play-to-Earn
;; Features: Tournament system, NFT rewards, skill-based matchmaking, prize pools

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-unauthorized (err u100))
(define-constant err-game-not-found (err u101))
(define-constant err-already-registered (err u102))
(define-constant err-insufficient-balance (err u103))
(define-constant err-tournament-full (err u104))
(define-constant err-invalid-score (err u105))
(define-constant err-already-claimed (err u106))
(define-constant err-tournament-active (err u107))
(define-constant err-not-eligible (err u108))
(define-constant err-paused (err u109))
(define-constant err-invalid-entry (err u110))
(define-constant err-cooldown-active (err u111))
(define-constant err-max-players (err u112))

;; Protocol Parameters
(define-constant entry-fee-basic u1000000) ;; 1 STX
(define-constant entry-fee-premium u10000000) ;; 10 STX
(define-constant entry-fee-elite u100000000) ;; 100 STX
(define-constant platform-fee u500) ;; 5% platform fee
(define-constant referral-bonus u200) ;; 2% referral bonus
(define-constant win-bonus-multiplier u3) ;; 3x multiplier for wins
(define-constant tournament-cooldown u144) ;; ~24 hours between tournaments
(define-constant max-players-per-tournament u100)
(define-constant max-tournaments-active u10)
(define-constant skill-rating-base u1500) ;; Starting ELO rating

;; Data Variables
(define-data-var game-counter uint u0)
(define-data-var tournament-counter uint u0)
(define-data-var total-prize-pool uint u0)
(define-data-var total-rewards-distributed uint u0)
(define-data-var platform-earnings uint u0)
(define-data-var active-players uint u0)
(define-data-var season-number uint u1)
(define-data-var platform-paused bool false)

;; Data Maps
(define-map players
    principal
    {
        username: (string-ascii 30),
        skill-rating: uint,
        games-played: uint,
        games-won: uint,
        tournaments-won: uint,
        total-earnings: uint,
        current-streak: uint,
        best-streak: uint,
        registered-at: uint,
        last-game: uint,
        is-banned: bool
    })

(define-map games
    uint ;; game-id
    {
        name: (string-ascii 50),
        game-type: (string-ascii 20),
        entry-fee: uint,
        prize-pool: uint,
        max-players: uint,
        current-players: uint,
        status: (string-ascii 20),
        created-at: uint,
        started-at: uint,
        ended-at: uint,
        winner: (optional principal)
    })

(define-map tournaments
    uint ;; tournament-id
    {
        name: (string-ascii 50),
        entry-fee: uint,
        prize-pool: uint,
        max-players: uint,
        registered-players: uint,
        start-time: uint,
        end-time: uint,
        status: (string-ascii 20),
        prize-distribution: (list 10 uint),
        minimum-skill: uint,
        maximum-skill: uint
    })

(define-map tournament-players
    { tournament-id: uint, player: principal }
    {
        score: uint,
        rank: uint,
        games-played: uint,
        eliminated: bool,
        prize-claimed: bool,
        registered-at: uint
    })

(define-map game-results
    { game-id: uint, player: principal }
    {
        score: uint,
        placement: uint,
        earnings: uint,
        time-taken: uint,
        verified: bool
    })

(define-map player-achievements
    { player: principal, achievement-id: uint }
    {
        unlocked: bool,
        unlocked-at: uint,
        progress: uint,
        reward-claimed: bool
    })

(define-map season-leaderboard
    { season: uint, rank: uint }
    {
        player: principal,
        points: uint,
        games-played: uint,
        win-rate: uint
    })

(define-map referrals
    principal ;; referrer
    {
        referred-count: uint,
        total-earnings: uint,
        active-referrals: uint,
        bonus-claimed: uint
    })

(define-map matchmaking-queue
    uint ;; skill-bracket (0-5000 in increments of 500)
    (list 20 principal))

;; Private Functions
(define-private (calculate-prize (entry-fee uint) (player-count uint) (placement uint))
    (let ((total-pool (- (* entry-fee player-count) (/ (* (* entry-fee player-count) platform-fee) u10000))))
        (if (is-eq placement u1)
            (/ (* total-pool u5000) u10000) ;; 50% for first
            (if (is-eq placement u2)
                (/ (* total-pool u3000) u10000) ;; 30% for second
                (if (is-eq placement u3)
                    (/ (* total-pool u2000) u10000) ;; 20% for third
                    u0)))))

(define-private (update-skill-rating (current-rating uint) (opponent-rating uint) (won bool))
    (let ((k-factor u32)
          (expected (/ u1000000 (+ u1000000 (pow u10 (/ (- opponent-rating current-rating) u400)))))
          (actual (if won u1000000 u0))
          (change (/ (* k-factor (- actual expected)) u1000000)))
        (if won
            (+ current-rating change)
            (if (> current-rating change)
                (- current-rating change)
                u0))))

(define-private (get-skill-bracket (rating uint))
    (/ rating u500))

(define-private (calculate-referral-bonus (amount uint))
    (/ (* amount referral-bonus) u10000))

(define-private (is-eligible-for-tournament (player principal) (min-skill uint) (max-skill uint))
    (match (map-get? players player)
        player-data (and (>= (get skill-rating player-data) min-skill)
                        (<= (get skill-rating player-data) max-skill)
                        (not (get is-banned player-data)))
        false))

;; Read-only Functions
(define-read-only (get-player (player principal))
    (ok (map-get? players player)))

(define-read-only (get-game (game-id uint))
    (ok (map-get? games game-id)))

(define-read-only (get-tournament (tournament-id uint))
    (ok (map-get? tournaments tournament-id)))

(define-read-only (get-tournament-player (tournament-id uint) (player principal))
    (ok (map-get? tournament-players { tournament-id: tournament-id, player: player })))

(define-read-only (get-player-stats (player principal))
    (match (map-get? players player)
        player-data (ok {
            win-rate: (if (> (get games-played player-data) u0)
                         (/ (* (get games-won player-data) u10000) (get games-played player-data))
                         u0),
            skill-rating: (get skill-rating player-data),
            total-earnings: (get total-earnings player-data),
            current-streak: (get current-streak player-data)
        })
        (err err-unauthorized)))

(define-read-only (get-platform-stats)
    (ok {
        total-games: (var-get game-counter),
        total-tournaments: (var-get tournament-counter),
        total-prize-pool: (var-get total-prize-pool),
        total-rewards: (var-get total-rewards-distributed),
        active-players: (var-get active-players),
        platform-earnings: (var-get platform-earnings),
        current-season: (var-get season-number)
    }))

(define-read-only (get-leaderboard-position (season uint) (rank uint))
    (ok (map-get? season-leaderboard { season: season, rank: rank })))

;; Public Functions
(define-public (register-player (username (string-ascii 30)))
    (let ((existing (map-get? players tx-sender)))
        ;; Validations
        (asserts! (is-none existing) err-already-registered)
        (asserts! (not (var-get platform-paused)) err-paused)
        
        ;; Register player
        (map-set players tx-sender {
            username: username,
            skill-rating: skill-rating-base,
            games-played: u0,
            games-won: u0,
            tournaments-won: u0,
            total-earnings: u0,
            current-streak: u0,
            best-streak: u0,
            registered-at: burn-block-height,
            last-game: u0,
            is-banned: false
        })
        
        ;; Update active players
        (var-set active-players (+ (var-get active-players) u1))
        
        (ok true)))

(define-public (create-game (name (string-ascii 50)) 
                           (game-type (string-ascii 20))
                           (entry-fee uint)
                           (max-players uint))
    (let ((game-id (+ (var-get game-counter) u1)))
        ;; Validations
        (asserts! (not (var-get platform-paused)) err-paused)
        (asserts! (or (is-eq entry-fee entry-fee-basic)
                     (is-eq entry-fee entry-fee-premium)
                     (is-eq entry-fee entry-fee-elite))
                 err-invalid-entry)
        (asserts! (<= max-players u20) err-max-players)
        
        ;; Create game
        (map-set games game-id {
            name: name,
            game-type: game-type,
            entry-fee: entry-fee,
            prize-pool: u0,
            max-players: max-players,
            current-players: u0,
            status: "waiting",
            created-at: burn-block-height,
            started-at: u0,
            ended-at: u0,
            winner: none
        })
        
        ;; Update counter
        (var-set game-counter game-id)
        
        (ok game-id)))

(define-public (join-game (game-id uint))
    (let ((game (unwrap! (map-get? games game-id) err-game-not-found))
          (player-data (unwrap! (map-get? players tx-sender) err-unauthorized)))
        
        ;; Validations
        (asserts! (not (var-get platform-paused)) err-paused)
        (asserts! (is-eq (get status game) "waiting") err-tournament-active)
        (asserts! (< (get current-players game) (get max-players game)) err-tournament-full)
        (asserts! (> (- burn-block-height (get last-game player-data)) u6) err-cooldown-active)
        
        ;; Pay entry fee
        (try! (stx-transfer? (get entry-fee game) tx-sender (as-contract tx-sender)))
        
        ;; Update game
        (map-set games game-id
                (merge game {
                    current-players: (+ (get current-players game) u1),
                    prize-pool: (+ (get prize-pool game) (get entry-fee game)),
                    status: (if (is-eq (+ (get current-players game) u1) (get max-players game))
                               "active"
                               "waiting")
                }))
        
        ;; Record player entry
        (map-set game-results 
                { game-id: game-id, player: tx-sender }
                {
                    score: u0,
                    placement: u0,
                    earnings: u0,
                    time-taken: u0,
                    verified: false
                })
        
        ;; Update player stats
        (map-set players tx-sender
                (merge player-data {
                    games-played: (+ (get games-played player-data) u1),
                    last-game: burn-block-height
                }))
        
        ;; Update global stats
        (var-set total-prize-pool (+ (var-get total-prize-pool) (get entry-fee game)))
        
        (ok true)))

(define-public (submit-score (game-id uint) (score uint))
    (let ((game (unwrap! (map-get? games game-id) err-game-not-found))
          (result (unwrap! (map-get? game-results { game-id: game-id, player: tx-sender })
                         err-unauthorized)))
        
        ;; Validations
        (asserts! (is-eq (get status game) "active") err-tournament-active)
        (asserts! (not (get verified result)) err-already-claimed)
        
        ;; Update score
        (map-set game-results 
                { game-id: game-id, player: tx-sender }
                (merge result {
                    score: score,
                    verified: true,
                    time-taken: (- burn-block-height (get started-at game))
                }))
        
        (ok true)))

(define-public (claim-game-prize (game-id uint))
    (let ((game (unwrap! (map-get? games game-id) err-game-not-found))
          (result (unwrap! (map-get? game-results { game-id: game-id, player: tx-sender })
                         err-unauthorized))
          (player-data (unwrap! (map-get? players tx-sender) err-unauthorized)))
        
        ;; Validations
        (asserts! (is-eq (get status game) "completed") err-tournament-active)
        (asserts! (> (get placement result) u0) err-not-eligible)
        (asserts! (is-eq (get earnings result) u0) err-already-claimed)
        
        ;; Calculate prize
        (let ((prize (calculate-prize (get entry-fee game) 
                                    (get current-players game)
                                    (get placement result)))
              (platform-cut (/ (* prize platform-fee) u10000))
              (net-prize (- prize platform-cut)))
            
            ;; Transfer prize
            (try! (as-contract (stx-transfer? net-prize tx-sender tx-sender)))
            
            ;; Update result
            (map-set game-results 
                    { game-id: game-id, player: tx-sender }
                    (merge result { earnings: net-prize }))
            
            ;; Update player stats
            (let ((is-winner (is-eq (get placement result) u1)))
                (map-set players tx-sender
                        (merge player-data {
                            games-won: (if is-winner 
                                         (+ (get games-won player-data) u1)
                                         (get games-won player-data)),
                            total-earnings: (+ (get total-earnings player-data) net-prize),
                            current-streak: (if is-winner
                                              (+ (get current-streak player-data) u1)
                                              u0),
                            best-streak: (if is-winner
                                           (if (> (+ (get current-streak player-data) u1) 
                                                 (get best-streak player-data))
                                               (+ (get current-streak player-data) u1)
                                               (get best-streak player-data))
                                           (get best-streak player-data))
                        })))
            
            ;; Update global stats
            (var-set total-rewards-distributed (+ (var-get total-rewards-distributed) net-prize))
            (var-set platform-earnings (+ (var-get platform-earnings) platform-cut))
            
            (ok net-prize))))

(define-public (create-tournament (name (string-ascii 50))
                                 (entry-fee uint)
                                 (max-players uint)
                                 (min-skill uint)
                                 (max-skill uint))
    (let ((tournament-id (+ (var-get tournament-counter) u1)))
        ;; Validations
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (asserts! (not (var-get platform-paused)) err-paused)
        (asserts! (<= max-players max-players-per-tournament) err-max-players)
        
        ;; Create tournament
        (map-set tournaments tournament-id {
            name: name,
            entry-fee: entry-fee,
            prize-pool: u0,
            max-players: max-players,
            registered-players: u0,
            start-time: (+ burn-block-height u144),
            end-time: (+ burn-block-height u1008),
            status: "registration",
            prize-distribution: (list u5000 u3000 u2000 u0 u0 u0 u0 u0 u0 u0),
            minimum-skill: min-skill,
            maximum-skill: max-skill
        })
        
        ;; Update counter
        (var-set tournament-counter tournament-id)
        
        (ok tournament-id)))

(define-public (join-tournament (tournament-id uint))
    (let ((tournament (unwrap! (map-get? tournaments tournament-id) err-game-not-found))
          (player-data (unwrap! (map-get? players tx-sender) err-unauthorized)))
        
        ;; Validations
        (asserts! (not (var-get platform-paused)) err-paused)
        (asserts! (is-eq (get status tournament) "registration") err-tournament-active)
        (asserts! (< (get registered-players tournament) (get max-players tournament)) err-tournament-full)
        (asserts! (is-eligible-for-tournament tx-sender 
                                             (get minimum-skill tournament)
                                             (get maximum-skill tournament)) 
                 err-not-eligible)
        
        ;; Pay entry fee
        (try! (stx-transfer? (get entry-fee tournament) tx-sender (as-contract tx-sender)))
        
        ;; Register player
        (map-set tournament-players 
                { tournament-id: tournament-id, player: tx-sender }
                {
                    score: u0,
                    rank: u0,
                    games-played: u0,
                    eliminated: false,
                    prize-claimed: false,
                    registered-at: burn-block-height
                })
        
        ;; Update tournament
        (map-set tournaments tournament-id
                (merge tournament {
                    registered-players: (+ (get registered-players tournament) u1),
                    prize-pool: (+ (get prize-pool tournament) (get entry-fee tournament))
                }))
        
        ;; Update global stats
        (var-set total-prize-pool (+ (var-get total-prize-pool) (get entry-fee tournament)))
        
        (ok true)))

(define-public (update-player-referral (referrer principal))
    (let ((referral-data (default-to { referred-count: u0, total-earnings: u0, 
                                      active-referrals: u0, bonus-claimed: u0 }
                                    (map-get? referrals referrer))))
        ;; Validations
        (asserts! (is-some (map-get? players referrer)) err-unauthorized)
        (asserts! (not (is-eq referrer tx-sender)) err-invalid-entry)
        
        ;; Update referral data
        (map-set referrals referrer
                (merge referral-data {
                    referred-count: (+ (get referred-count referral-data) u1),
                    active-referrals: (+ (get active-referrals referral-data) u1)
                }))
        
        (ok true)))

;; Admin Functions
(define-public (pause-platform)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (var-set platform-paused true)
        (ok true)))

(define-public (unpause-platform)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (var-set platform-paused false)
        (ok true)))

(define-public (ban-player (player principal))
    (let ((player-data (unwrap! (map-get? players player) err-unauthorized)))
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (map-set players player
                (merge player-data { is-banned: true }))
        (ok true)))

(define-public (start-new-season)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (var-set season-number (+ (var-get season-number) u1))
        (ok (var-get season-number))))

(define-public (withdraw-platform-fees (amount uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (asserts! (<= amount (var-get platform-earnings)) err-insufficient-balance)
        (try! (as-contract (stx-transfer? amount tx-sender contract-owner)))
        (var-set platform-earnings (- (var-get platform-earnings) amount))
        (ok amount)))