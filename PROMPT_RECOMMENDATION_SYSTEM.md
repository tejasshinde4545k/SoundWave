# Music Recommendation System — Production Prompt

> **Target App:** SoundWave (Flutter, YouTube-sourced audio)
> **Stack Preference:** Startup-friendly (SQLite → PostgreSQL, ONNX/ML Kit for on-device, Python FastAPI for cloud)
> **Phasing:** MVP → Enhanced → Advanced

---

## 1. Objective and Scope

### 1.1 Goal
Build a recommendation system that predicts the **next song** and generates **personalized playlists** that maximize:
- **User engagement** (session duration, return rate, playlist completion)
- **User satisfaction** (likes, shares, saves, explicit positive feedback)
- **Discovery quality** (serendipity, diversity, novelty without being jarring)

### 1.2 Personalization Dimensions
1. **History-based**: past plays, skips, likes, search queries, playlist additions
2. **Context-aware**: time of day, day of week, device type, listening mode (focus, workout, relaxing)
3. **Behavioral**: recency decay, frequency normalization, skip patterns (skip-in-first-5s vs skip-at-end)
4. **Diversity**: avoid echo chambers by injecting candidates from outside the user's dominant genres/artists/languages
5. **Cold-start handling**: new users get onboarding preference surveys; new tracks use content-based metadata

### 1.3 Constraints
| Constraint | Target |
|---|---|
| Inference latency (next-song) | ≤ 200ms p95 |
| Inference latency (playlist gen) | ≤ 1s p95 |
| Scale target (MVP) | 1K–10K users |
| Scale target (Enhanced) | 10K–100K users |
| Privacy | No raw IP/sticky IDs; anonymized user keys |
| Data retention | Aggregated stats: indefinite. Per-session raw logs: 90 days |

---

## 2. Data and Features

### 2.1 Raw Input Data Sources

**Interactions (user_song_events)**
```sql
-- MVP schema (SQLite, then migrate to PostgreSQL)
CREATE TABLE user_song_events (
  user_id          TEXT    NOT NULL,      -- anonymized hash
  ytid             TEXT    NOT NULL,      -- YouTube video ID
  event_type       TEXT    NOT NULL,      -- 'play' | 'skip' | 'like' | 'dislike' | 'save_to_playlist'
  session_id       TEXT    NOT NULL,
  timestamp_utc    INTEGER NOT NULL,      -- unix epoch seconds
  listened_seconds REAL,
  duration_seconds REAL,
  device           TEXT,                  -- 'mobile' | 'desktop' | 'tablet'
  hour_of_day      INTEGER,
  day_of_week      INTEGER
);
CREATE INDEX idx_events_user_time ON user_song_events(user_id, timestamp_utc);
CREATE INDEX idx_events_ytid ON user_song_events(ytid);
```

**Track metadata (track_metadata)**
```sql
CREATE TABLE track_metadata (
  ytid        TEXT PRIMARY KEY,
  title       TEXT NOT NULL,
  artist      TEXT NOT NULL,
  album       TEXT,
  genre       TEXT,
  subgenres   TEXT,            -- comma-separated
  tempo_bpm   REAL,
  mood        TEXT,            -- 'energetic' | 'calm' | 'melancholy' | 'happy'
  popularity  REAL DEFAULT 0,  -- global popularity 0..1
  language    TEXT,
  region_hot  TEXT,            -- region where it's trending
  is_explicit INTEGER DEFAULT 0,
  duration_seconds REAL
);
```

**User preferences (user_profiles)** — built from interactions + onboarding survey
```sql
CREATE TABLE user_profiles (
  user_id             TEXT PRIMARY KEY,
  top_artists_json    TEXT,    -- '{"artist1": 0.4, "artist2": 0.3}'
  top_genres_json     TEXT,
  language_affinities_json TEXT,
  avg_session_duration REAL,
  total_plays         INTEGER DEFAULT 0,
  cold_start          INTEGER DEFAULT 1,
  created_at          INTEGER NOT NULL
);
```

### 2.2 Feature Engineering Pipeline

#### 2.2.1 User Features
| Feature | Method | Update Cadence |
|---|---|---|
| User embedding (d=64) | Trained via neural MF or Word2Vec on play sequences | Daily batch |
| Top-artist affinity vector | TF-IDF weighted by normalized play count | Per-event incremental |
| Genre preference vector | Soft counts with time-decay (λ=0.95 per week) | Per-event incremental |
| Session recency | Exponential decay: `score *= 0.9^(days_ago)` | Real-time |
| Avg skip rate (7d window) | `skips / (plays+skips)` rolling window | Daily batch |
| Active hour silhouette | Mode of `hour_of_day` in recent 30 plays | Per-event |

#### 2.2.2 Track Features
| Feature | Method | Update Cadence |
|---|---|---|
| Track embedding (d=64) | Trained via neural MF or contrastive learning | Weekly batch |
| Audio features | Tempo, loudness, danceability (extracted via librosa or Spotify API) | On ingest |
| Popularity percentile | Global rank normalized 0..1 | Daily batch |
| Content freshness | `1 / (1 + days_since_release)` | On ingest |
| Artist popularity | Mean popularity of artist's tracks | Daily batch |
| Language/region tag | From metadata or detected via audio | On ingest |

#### 2.2.3 Context Features
- `hour_sin`, `hour_cos` (cyclical encoding of time of day)
- `day_sin`, `day_cos` (cyclical encoding of day of week)
- `is_weekend` (binary)
- `device_type_encoded` (one-hot or embedding)
- `session_position` (normalized 0..1 — where in the current session)
- `previous_skip_ratio` (of last 5 songs)

#### 2.2.4 Cross Features
- Cosine similarity(user_embedding, track_embedding)
- Whether user liked/played this artist before
- Whether user liked/played tracks in this genre before
- Recency score of this track for this user

### 2.3 Data Quality and Privacy

**Anonymization Pipeline**
```
┌─────────────┐    ┌──────────────┐    ┌───────────────┐
│ Raw event   │ →  │ Hash user_id │ →  │ Strip IP/UA   │ →  Feature Store
│ (user_id,   │    │ (SHA-256 +   │    │ Remove fields │
│  ytid, ...) │    │  per-app     │    │ not in schema │
└─────────────┘    │  salt)       │    └───────────────┘
                   └──────────────┘
```

- **Consent**: Collect only when user opts into "Personalize recommendations"
- **Retention**: Raw events purged after 90 days; aggregated user profiles kept
- **Right to delete**: Expose a "Clear my listening history" button that re-hashes the user_id and zeroes the profile

---

## 3. Model Architecture and Approaches

### 3.1 Two-Tower Architecture (MVP+)

```
                            ┌─────────────────────┐
                            │   Ranked candidate  │
                            │   list (top-50)     │
                            └──────────┬──────────┘
                                       │
                            ┌──────────▼──────────┐
                            │   Ranking Model      │
                            │   (LightGBM or       │
                            │    small DNN, 2-3    │
                            │    hidden layers)    │
                            │                     │
                            │ Input: user_feats + │
                            │ track_feats + cross │
                            └──┬──────────────┬───┘
                               │              │
                    ┌──────────▼──┐     ┌─────▼────────┐
                    │ User Tower  │     │ Track Tower  │
                    │ (d=64 → 32) │     │ (d=64 → 32) │
                    │ MLP(64,32)  │     │ MLP(64,32)  │
                    └──────┬──────┘     └──────┬───────┘
                           │                   │
                    ┌──────▼──────┐     ┌──────▼───────┐
                    │ User        │     │ Track        │
                    │ Embedding   │     │ Embedding    │
                    │ (d=64)      │     │ (d=64)       │
                    └─────────────┘     └──────────────┘
```

#### Candidate Generation (Retrieval)
1. **Embedding-based ANN** (MVP: FAISS on CPU with IVF index, Enhanced: HNSW)
   - Query vector = user_embedding ⊙ context_vector
   - Retrieve top-200 nearest track embeddings
2. **Co-occurrence based** (fallback for cold tracks/users)
   - "Users who liked X also liked Y" from frequent itemsets
   - Jaccard similarity on playlist co-occurrence
3. **Heuristic baselines** (always included for diversity)
   - New releases from top-3 user artists (5 tracks)
   - Trending in user's region (5 tracks)
   - Random sample from global pool (3 tracks)

#### Ranking (Scoring)
- **Primary model**: LightGBM (handles tabular features well, interpretable)
- **Alternative**: Small DNN (2 hidden layers, 128→64→1, ReLU)
- **Input features**: 40–60 features mixing user, track, context, cross
- **Target**: `label = 1.0` for completed plays (>70% of duration), `0.3` for partial, `0.0` for skips within 10s, `-0.1` for dislikes

### 3.2 Exploration vs Exploitation

**Epsilon-Greedy (MVP)**
- ε = 0.1: 10% of requests, serve from the diversity pool instead of top-ranked
- Decay ε over time for mature users (`ε = 0.1 * max(0, 1 - plays/500)`)

**Multi-Armed Bandit (Enhanced)**
- Track cold-start as Thompson Sampling per genre cluster
- Each genre cluster = one Beta-Bandit; prior = α=2, β=10 for new tracks
- After 50 impressions, hand over to the ranking model's score

**Contextual Bandit (Advanced)**
- LinUCB for playlist generation
- Each arm = playlist theme (mood/activity)
- User context vector as the context

### 3.3 Cold-Start Handling

**New Track**
1. Extract audio features → find nearest neighbors in embedding space
2. Assign initial popularity = mean popularity of artist's existing tracks
3. Temporary embedding = average of 10 nearest tracks in feature space
4. After 20 user interactions, replace with learned embedding

**New User**
1. Onboarding survey (pick 3+ artists/genres you like)
2. Seed embedding = centroid of selected artists' embeddings
3. First session: weight popularity × 3, weight diversity × 2
4. After 50 plays, cold_start flag → false, use standard pipeline

### 3.4 Latency and Serving Architecture

```
┌──────────────┐     ┌─────────────┐     ┌───────────────┐
│ Flutter App  │ ←→  │ FastAPI     │ ←→  │ Redis Cache   │
│ (client)     │     │ (ranking    │     │ (top-50       │
│              │     │  endpoint)  │     │  per user)    │
└──────────────┘     └──────┬──────┘     └───────────────┘
                            │
                     ┌──────▼──────┐     ┌───────────────┐
                     │ Python      │ ←→  │ Feature Store │
                     │ Ranking     │     │ (PostgreSQL   │
                     │ Worker(s)   │     │  + Redis)     │
                     └─────────────┘     └───────────────┘
```

**Caching strategy:**
- Precompute top-100 candidates for each user every 4 hours → Redis
- On request: rank, return, async-update impressions
- On explicit negative feedback (dislike, skip): adjust score in real-time, recount

**Offline training pipeline (Airflow / Prefect):**
```
Daily trigger
 │
 ├── 1. Pull events from past 7 days
 ├── 2. Compute features (user, track, cross)
 ├── 3. Train ranking model (LightGBM)
 ├── 4. Evaluate on validation window (last 24h)
 ├── 5. Push to model registry
 └── 6. Warm Redis caches with new embeddings
```

---

## 4. Training Protocol and Evaluation

### 4.1 Offline Metrics

| Metric | Target (MVP) | Target (Enhanced) | Notes |
|---|---|---|---|
| Recall@20 | ≥ 0.35 | ≥ 0.45 | Did the user interact with any of top-20? |
| NDCG@10 | ≥ 0.40 | ≥ 0.50 | Ranking quality weighted by position |
| MAP@50 | ≥ 0.25 | ≥ 0.35 | Mean average precision |
| Intra-list diversity | ≥ 0.30 | ≥ 0.40 | 1 - mean cosine sim of track embeddings in list |
| Novelty@20 | ≥ 0.15 | ≥ 0.25 | Proportion of recommended tracks the user hasn't heard |
| Serendipity | ≥ 0.10 | ≥ 0.15 | Positive interactions on tracks outside user's top-3 genres |

**Validation Protocol**
```python
# Time-based split — critical for recsys to avoid lookahead bias
def train_validation_split(events, train_days=6, val_days=1):
    max_ts = events['timestamp'].max()
    split_ts = max_ts - pd.Timedelta(days=val_days)
    train = events[events['timestamp'] < split_ts]
    val = events[events['timestamp'] >= split_ts]
    return train, val
```

- Walk-forward validation: train on D-7..D-1, validate on D (sliding 7-day window)
- Ensure no user in validation set is completely unseen (filter to users with ≥5 training plays)

### 4.2 Online Experimentation (A/B Testing)

**Design:**
```
┌─────────┐     ┌──────────────┐     ┌───────────────┐
│ 90% of  │     │ Control      │     │ Current       │
│ users   │     │ (production  │     │ production    │
│         │     │  model)      │     │ metrics       │
├─────────┤     ├──────────────┤     ├───────────────┤
│ 10% of  │     │ Treatment    │     │ New model     │
│ users   │     │ (candidate   │     │ metrics       │
│         │     │  model)      │     │               │
└─────────┘     └──────────────┘     └───────────────┘
```

**KPIs (minimum 2-week run, 5% significance threshold):**

| KPI | Definition | Direction |
|---|---|---|
| CTR (recommendation) | Clicks on recommended item / impressions | ↑ |
| Listen-through rate | Plays lasting >70% of track duration | ↑ |
| Skip rate (first 10s) | Skips within 10s / total plays | ↓ |
| Session duration | Minutes per active session | ↑ |
| 7-day return rate | Users who come back within 7 days | ↑ |
| Exploration acceptance | Positive interactions on low-popularity (<20th percentile) tracks | ↑ |
| Per-genre engagement | Skew toward top genre — track for echo chamber mitigation | →1 |

**Safety gates:** If any KPI degrades >5% with p<0.1, auto-rollback.

### 4.3 Safety & Quality Gates

1. **Bias monitoring**: per-genre, per-artist, per-language recommendation rate should not deviate >2x from catalog proportion
2. **Explicit content filter**: if `track_metadata.is_explicit == 1` and user profile indicates under-18 OR explicit_content_opt_out == true, block
3. **Toxicity guard**: regex/ML filter on track title and metadata for hate speech, violence
4. **Repetition guard**: do not recommend the same track twice in 24h; do not recommend >2 tracks from same artist in top-10
5. **Accessibility**: all recommended tracks must have ≥50% speech-to-lyrics coverage (for hearing-impaired users who read lyrics)

---

## 5. Deployment and Maintenance

### 5.1 MLOps Stack (Startup-Friendly)

```
┌─────────────────────────────────────────────────────────┐
│                     CI/CD Pipeline                       │
│  GitHub Actions → build docker → push to registry →     │
│  deploy to Render / Railway / fly.io                    │
└─────────────────────────────────────────────────────────┘

┌───────────┐  ┌──────────┐  ┌───────────┐  ┌───────────┐
│ Feature   │  │ Model    │  │ Model     │  │ ML        │
│ Store     │  │ Registry │  │ Serving   │  │ Pipeline  │
│ (SQLite → │  │ (DVC +   │  │ (FastAPI  │  │ (Prefect) │
│  PG)      │  │  S3/GCS) │  │  + ONNX)  │  │           │
└───────────┘  └──────────┘  └───────────┘  └───────────┘
```

**Component details (MVP):**
- **Feature Store**: PostgreSQL + Redis cache (ElastiCache or local)
- **Model Registry**: DVC + S3-compatible storage (Backblaze B2 or MinIO)
- **Model Serving**: ONNX runtime via FastAPI (float32, quantized to int8 for mobile)
- **Pipeline Orchestrator**: Prefect (free tier handles MVP scale)
- **Monitoring**: self-hosted Grafana + Prometheus, or Datadog free tier

**Component details (Enhanced):**
- **Feature Store**: Feast (open-source) on PostgreSQL
- **Model Registry**: MLflow
- **Batch Serving**: Spark (or Polars on a single large instance)
- **Monitoring**: WhyLabs or Evidently AI for data drift

### 5.2 Monitoring Dashboard

```
┌──────────────────────────────────────────────────────────────────┐
│                       RECOMMENDATION SYSTEM DASHBOARD            │
├─────────────┬─────────────┬──────────────┬───────────────────────┤
│ Latency p50 │ Latency p95 │ Error Rate   │ Cache Hit Rate        │
│   85ms      │   190ms     │    0.02%     │     87%               │
├─────────────┴─────────────┴──────────────┴───────────────────────┤
│          Online KPIs (last 7d vs prior 7d)                       │
│  CTR: +2.1%  |  SkipRate: -1.4%  |  SessionDur: +0.8%          │
├──────────────────────────────────────────────────────────────────┤
│          Data Drift Alerts                                       │
│  ⚠ User embedding drift detected (PSI=0.12 > threshold 0.1)    │
│    → Recommendation: retrain user tower                         │
└──────────────────────────────────────────────────────────────────┘
```

### 5.3 Privacy and Compliance

- **GDPR / CCPA ready**: User controls for export, deletion, opt-out
- **Data minimization**: Store only features, never raw behavioral sequences beyond 90 days
- **Audit trail**: All model predictions logged with timestamp, user hash, model version, feature hash
- **On-device option (Future)**: Run candidate generation + ranking via TFLite/ML Kit on the phone; server only for metadata sync

---

## 6. Deliverables

### 6.1 For Model Trainers — Prompt Template

```text
## Training Session: Next-Song Prediction

### Task
Train a ranking model to predict the probability a user will fully listen to
a candidate track when offered as the next song.

### Input
- File `events_parquet/date={YYYY-MM-DD}/part-*.parquet` with schema
  described in §2.1.
- Precomputed features from feature store at `features/` — join on
  (user_id, ytid, session_id).

### Training Command (MVP)
```
python train_ranker.py \
    --data-dir s3://soundwave-features/ranknet-data/ \
    --model-type lightgbm \
    --params '{"learning_rate": 0.05, "num_leaves": 64, "max_depth": 7}' \
    --epochs 300 \
    --early-stopping 50 \
    --val-days 1 \
    --output-dir models/$(date +%Y%m%d)/ranker_v1
```

### Evaluation
```
python evaluate.py \
    --model models/$(date +%Y%m%d)/ranker_v1/model.txt \
    --test-data s3://soundwave-features/ranknet-data/val/ \
    --metrics ndcg@10 recall@20 map@50 diversity novelty
    > reports/$(date +%Y%m%d)_eval.json
```

### Gate to pass before registry
- NDCG@10 ≥ 0.40 (or +2% over current production)
- No metric regresses >1% on any subpopulation (genres A–F)
- Latency < 5ms per prediction on CPU (single core)
- Model size < 50 MB
```

### 6.2 For Data Engineers — Pipeline Prompt Template

```text
## Pipeline: Feature Computation — Daily Batch

### Schedule
04:00 UTC daily, after events are landed.

### Steps
1. **raw_events → clean_events**
   - Filter: user consent flag = true
   - Anonymize: hash user_id with app-specific salt
   - Validate: drop rows with null ytid or null timestamp
   - Output: `s3://soundwave-clean/events/dt={YYYY-MM-DD}/`

2. **clean_events → user_features**
   - Aggregate per user per day:
     - Total plays, skips, likes, dislikes
     - Per-artist play counts (top-20)
     - Per-genre play counts (top-10)
     - Rolling skip-rate over 7-day window (SQL window function)
     - Session count, avg session length
   - Apply recency decay: weight = exp(-0.05 * days_since_event)
   - Output: `s3://soundwave-features/users/dt={YYYY-MM-DD}/`

3. **clean_events + track_metadata → track_features**
   - Global popularity = percentile(play_count_last_7d)
   - Per-track skip rate
   - Co-occurrence matrix (top-100 item pairs)
   - Output: `s3://soundwave-features/tracks/dt={YYYY-MM-DD}/`

4. **Trigger re-training if**
   - New features added (manual)
   - Feature drift PSI > 0.1 (auto)
   - Calendar cron: every 7 days (auto)

### SLA
Pipeline completes by 06:30 UTC. Alert if >07:00.
```

### 6.3 For Product Managers — Decision Prompt Template

```text
## Experiment Proposal: Next-Song Ranking v2.1

### Hypothesis
Replacing LightGBM with a 2-layer DNN (128→64) will increase listen-through
rate by 3% by capturing non-linear feature interactions.

### Experiment Design
- **Duration**: 14 days minimum
- **Traffic**: 10% of active users (min 500 users)
- **Control**: Current LightGBM model (v2.0)
- **Treatment**: DNN model (v2.1)
- **Success criteria** (must meet ALL):
  ┌─────────────────────────┬────────────┬──────────┐
  │ Metric                  │ Minimum Δ  │ Direction │
  ├─────────────────────────┼────────────┼──────────┤
  │ Listen-through rate     │ +1.5%      │ ↑        │
  │ CTR (recs)              │ not worse  │ ≥        │
  │ Skip rate (first 10s)   │ not worse  │ ≤        │
  │ Session duration        │ not worse  │ ≥        │
  │ Diversity               │ not worse  │ ≥        │
  └─────────────────────────┴────────────┴──────────┘
- **Auto-rollback**: If any KPI degrades >5% (p < 0.1).

### Decision template after experiment
```json
{
  "experiment_id": "rec-ranker-v2.1-20250701",
  "decision": "promote" | "revert",
  "evidence": {
    "listen_through_rate": {"control": 0.412, "treatment": 0.431, "delta_pct": 4.6, "p_value": 0.02},
    "ctr":              {"control": 0.083, "treatment": 0.081, "delta_pct": -2.4, "p_value": 0.15},
    "skip_rate":        {"control": 0.21,  "treatment": 0.20,  "delta_pct": -4.8, "p_value": 0.08},
    "session_duration": {"control": 1240,  "treatment": 1265,  "delta_pct": 2.0,  "p_value": 0.10},
    "diversity":        {"control": 0.35,  "treatment": 0.37,  "delta_pct": 5.7,  "p_value": 0.03}
  },
  "risks": ["DNN less interpretable than GBM", "2x memory at inference"],
  "signed_off_by": "recsys-pm@"
}
```

### Evaluation Plan Rubric

| Phase | Criteria | Weight | Pass Threshold |
|---|---|---|---|
| Offline validation | Recall@20 ≥ baseline | Must pass | +0% vs baseline |
| Offline validation | NDCG@10 ≥ baseline | Must pass | +0% vs baseline |
| Offline validation | Diversity ≥ 0.30 | 20% | ≥0.30 |
| Staging canary | Latency p95 < 200ms | Must pass | <200ms |
| Staging canary | No OOM/error on 50 req/s × 5min | Must pass | 0 errors |
| A/B test | Listen-through rate | 35% | +1.5% significant |
| A/B test | Session duration | 25% | Not worse |
| A/B test | CTR | 20% | Not worse |
| A/B test | Skip rate | 20% | Not worse |
```

---

## 7. Phased Plan

### Phase 1: MVP (Weeks 1–6)

**Goal**: Functional next-song recommendation using heuristics + basic ML.

| Week | Milestone | Deliverable |
|---|---|---|
| 1–2 | Data pipeline | SQLite schema, event logger in app, daily Parquet export |
| 3 | Embeddings | Train user + track embeddings via co-occurrence matrix (SVD) or Word2Vec on play sequences (d=32) |
| 4 | Candidate generation | ANN retrieval (FAISS IVF, top-100) + heuristic pool (new tracks, trending, random) |
| 5 | Ranking | LightGBM ranker with 20 features — train on 7-day window, evaluate on next 24h |
| 6 | API + integration | FastAPI endpoint `/api/v1/recommend/next` → Flutter app integration |

**MVP stack:**
- Python 3.11 + LightGBM + FAISS (CPU)
- SQLite (dev) → PostgreSQL (prod via Render/Railway)
- Flutter http client → FastAPI → Redis cache
- GitHub Actions CI

**MVP deliverables:**
- [x] Event logging in app (play, skip, like, dislike)
- [x] Daily feature computation script
- [x] LightGBM ranker training script
- [x] FastAPI serving endpoint
- [x] Redis caching layer
- [x] Basic A/B test infrastructure (split user IDs via modulus)

### Phase 2: Enhanced (Weeks 7–14)

**Goal**: Personalized playlist generation, cold-start resolution, bandit exploration.

| Week | Milestone | Deliverable |
|---|---|---|
| 7–8 | Playlist generation | Seq2Seq or set-embedding approach: given N seed tracks, predict the next M tracks; evaluate with NDCG and diversity |
| 9–10 | Cold-start pipeline | Onboarding survey UI + content-based embedding initialization |
| 11–12 | Exploration | Thompson Sampling per genre cluster for new tracks; ε-greedy (ε=0.05) for mature users |
| 13–14 | A/B testing framework | Self-serve experiment launch via config file; auto-rollback on KPI degradation |

### Phase 3: Advanced (Weeks 15–22)

**Goal**: Neural ranking, on-device inference, session-aware recommendations.

| Week | Milestone | Deliverable |
|---|---|---|
| 15–16 | Neural two-tower | Replace LightGBM with small DNN; train with in-batch negatives |
| 17–18 | On-device option | Convert ranking model to TFLite; run candidate re-ranking on phone |
| 19–20 | Session-aware | Add sequence model (GRU/Transformer over last 20 plays) as a feature encoder |
| 21–22 | Dashboard | Grafana dashboard for latency, KPIs, data drift, feature importance |

---

## Appendix A: Prompt Snippets for Common Tasks

### A.1 Retrain Ranking Model

```bash
# Activate environment
source .venv/bin/activate

# Pull latest features from feature store
python -m recsys.features.pull --days 7 --output ./data/features/

# Train
python -m recsys.train.ranker \
    --train-data ./data/features/train.parquet \
    --val-data ./data/features/val.parquet \
    --config configs/ranker_v2.yaml \
    --output ./models/$(date +%Y%m%d)_ranker_v2/

# Evaluate
python -m recsys.evaluate \
    --model ./models/$(date +%Y%m%d)_ranker_v2/ \
    --test-data ./data/features/test.parquet \
    --metrics ndcg@10 recall@20 map@50 diversity

# Register
python -m recsys.registry.register \
    --model-path ./models/$(date +%Y%m%d)_ranker_v2/ \
    --metrics-path ./reports/$(date +%Y%m%d)_eval.json \
    --notes "Added session_position and previous_skip_ratio features"
```

### A.2 Generate Personalized Playlist

```python
from recsys.playlist import PlaylistGenerator

generator = PlaylistGenerator(
    retrieval_top_k=200,
    ranking_model_path="models/latest/ranker/",
    diversity_weight=0.3,
    target_size=20,
)

playlist = generator.generate(
    user_id="user_abc123",
    seed_tracks=["ytid_1", "ytid_2", "ytid_3"],
    seed_type="explicit",           # 'explicit' | 'history' | 'mood'
    mood_target="energetic",        # optional signal
    exclude_recent_n_hours=24,
)

print(playlist.to_json())
# [
#   {"ytid": "ytid_A", "title": "...", "artist": "...", "score": 0.92},
#   {"ytid": "ytid_B", "title": "...", "artist": "...", "score": 0.88},
#   ...
# ]
```

### A.3 Evaluate Candidate Generation

```python
from recsys.evaluation import CandidateEvaluator

evaluator = CandidateEvaluator(
    retrieval=ann_index,
    train_events="data/features/train.parquet",
    test_events="data/features/test.parquet",
)

report = evaluator.evaluate(
    k_values=[10, 20, 50],
    metrics=["recall", "hit_rate", "diversity", "novelty"],
)

# Output
print(report.summary())
# ┌────────┬──────────┬────────┬───────────┬─────────┐
# │   k    │ recall   │ hit    │ diversity │ novelty │
# ├────────┼──────────┼────────┼───────────┼─────────┤
# │   10   │  0.21    │ 0.45   │   0.38    │  0.18   │
# │   20   │  0.37    │ 0.61   │   0.35    │  0.22   │
# │   50   │  0.52    │ 0.78   │   0.31    │  0.25   │
# └────────┴──────────┴────────┴───────────┴─────────┘
```

---

## Appendix B: References to Existing SoundWave Code

| Component | File | What to extend |
|---|---|---|
| Recommendation engine | `lib/services/recommendation_engine.dart` | Replace heuristic scoring with ML model prediction |
| Recommendation cache | `lib/services/recommendation_cache.dart` | Already LRU; add TTL config + warm via background fetch |
| Listening stats | `lib/services/listening_stats_service.dart` | Log to new `user_song_events` table instead of Hive-only |
| Music region | `lib/services/music_region_service.dart` | Expose language/region features for ranking model |
| Playlist manager | `lib/services/playlists_manager.dart` | Add "generate for me" button that calls the playlist endpoint |
| Data manager | `lib/services/data_manager.dart` | Add recommendation feature tables alongside existing Hive boxes |

---

## Appendix C: Quick-Start Commands

```bash
# Clone and set up
git clone https://github.com/tejasshinde4545k/SoundWave
cd SoundWave

# Create Python environment for ML pipeline
python -m venv .venv/recsys
source .venv/recsys/bin/activate  # Linux/macOS
# .venv\recsys\Scripts\activate   # Windows

# Install ML dependencies
pip install lightgbm pandas polars fastapi uvicorn redis faiss-cpu \
            scikit-learn prefect dvc-s3

# Run daily feature computation
python scripts/compute_features.py --date $(date +%Y-%m-%d)

# Train initial model
python scripts/train_ranker.py --config configs/ranker_mvp.yaml

# Start serving API
uvicorn recsys.api:app --host 0.0.0.0 --port 8000

# Test endpoint
curl -X POST http://localhost:8000/api/v1/recommend/next \
  -H "Content-Type: application