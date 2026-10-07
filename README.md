# home-credit-project
**Jake Hoopes**

Project Description:
Many people struggle to get loans because they have little or no credit history. Home Credit Group aims to improve financial inclusion by using alternative data, such as transactional and telecommunications information, to better predict whether borrowers can repay loans. The goal is to improve these predictions so qualified borrowers are not unfairly rejected and receive loans they can successfully repay.

## Repository contents

| File | What it is |
|---|---|
| [homecredit-eda/eda.qmd](homecredit-eda/eda.qmd) | Exploratory data analysis notebook (rendered: [eda.html](homecredit-eda/eda.html)) |
| [data_preparation.R](data_preparation.R) | Data preparation script: cleaning, feature engineering, bureau aggregation, train/test consistency |
| [homecredit-eda/modeling.qmd](homecredit-eda/modeling.qmd) | Modeling notebook: benchmark, model comparison, imbalance experiment, tuning, holdout evaluation, Kaggle submission (rendered: [modeling.html](homecredit-eda/modeling.html)) |
| [.gitignore](.gitignore) | Keeps raw data, prepared data, model objects (`models/`), and submissions (`submissions/`) out of the repository |

## Getting the data

The data comes from the Kaggle [Home Credit Default Risk](https://www.kaggle.com/c/home-credit-default-risk/data) competition and is not committed here because of its size (about 2.7 GB). Download it and place the CSV files in `homecredit-eda/data/`.

---

## Data preparation

[`data_preparation.R`](data_preparation.R) turns the decisions recorded in the EDA notebook into reusable R functions. It cleans the application data, engineers features, aggregates the bureau table to one row per applicant, joins everything together, and applies the exact same transformations to the train and test files. Every function is documented, and each transformation carries an `EDA:` comment naming the notebook section whose decision it implements.

### How to run

From the repository root:

```
Rscript data_preparation.R
```

Or from an R session, to reuse the functions:

```r
source("data_preparation.R")
result <- run_data_preparation()   # returns train, test, params, checks

# Or step by step:
raw        <- load_raw_data("homecredit-eda/data")
bureau_agg <- aggregate_bureau(raw$bureau)
train      <- prepare_application(raw$train, bureau_agg)                       # learns params
test       <- prepare_application(raw$test,  bureau_agg, params = train$params) # reuses them
```

Requires R and the `tidyverse`. A full run takes about 30 seconds.

### Inputs and outputs

| Input (in `homecredit-eda/data/`) | Rows × columns |
|---|---|
| `application_train.csv` | 307,511 × 122 |
| `application_test.csv` | 48,744 × 121 |
| `bureau.csv` | 1,716,428 × 17 |

| Output (in `homecredit-eda/data/prepared/`, git-ignored) | Rows × columns | Contents |
|---|---|---|
| `train_prepared.rds` | 307,511 × 169 | `SK_ID_CURR`, `TARGET`, and 167 features |
| `test_prepared.rds` | 48,744 × 168 | `SK_ID_CURR` and the same 167 features |
| `prep_params.rds` | — | Every parameter learned from train (see below) |

The outputs are `.rds` files so that factor levels survive saving. They contain no missing values: numeric features are imputed and categorical features are factors with fixed levels.

### What the script does, and which EDA decision each step implements

The 122 raw application columns become 167 features. Seven raw columns are removed (the six inquiry counts and `FLAG_MOBIL`), five `DAYS_` columns are replaced by year versions, and 57 new columns are added.

**Cleaning**

| Transformation | EDA decision it implements |
|---|---|
| `DAYS_EMPLOYED` value 365243 recoded to missing; new `not_currently_employed` flag | §3.3 / Q5: the value is a sentinel (1,000 years), 99.96% pensioners, who default at 5.4% vs 8.7%. It is a category, not a measurement. |
| `AMT_INCOME_TOTAL` capped at the train 99th percentile (472,500) | Q3: the income tail is not credible (max 117 million). Cap it, don't delete the rows. |
| Six `AMT_REQ_CREDIT_BUREAU_*` columns dropped; replaced by a `no_inquiry_data` flag | Q9: the counts are weak (best r = +0.02) and the one-month window runs backwards, but a missing inquiry block predicts 10.3% vs 7.7% default. |
| `FLAG_MOBIL` dropped | §3.3: it is 0 for exactly one applicant, so there is nothing to learn from it. |
| Rare categorical levels (< 50 train rows) pooled into "Other", or folded into the most common level if "Other" would itself be rare | §3.5 / Q7: XNA gender (4), Maternity leave (5), Unknown family status (2), Unemployed (22) give unreliable rates and empty test dummies. XNA → F and Unknown → Married; the small income types pool into "Other". |
| Missing categorical values become an explicit `"Missing"` level | §3.2: missing `OCCUPATION_TYPE` is informative (6.5% vs 8.8%, mostly pensioners). |
| Remaining numeric gaps filled with the train median; rows are never dropped | §3.2: dropping rows with gaps would remove the riskiest applicants. |
| `AMT_CREDIT > AMT_GOODS_PRICE` left unchanged | §3.3: true on 64.6% of loans and not an error, since fees are financed into the loan. |

**Engineered features**

| Feature(s) | EDA basis |
|---|---|
| `age_years`, `years_employed`, `years_since_registration`, `years_since_id_publish`, `years_since_phone_change` | Negative day counts converted to positive years. Q8: age runs 12.3% → 4.9% default; Q5: tenure runs 11.0% → 5.2%. |
| `employed_share_of_life` (tenure ÷ age) | Q5 + Q8: both measure stability; this separates short tenure because of youth from short tenure because of a recent job change. |
| `ltv` (credit ÷ goods price) | Q4: 5.1% at 1.00–1.10 rising to 12.8% above 1.30. |
| `pti` (annuity ÷ income), `credit_to_income`, `credit_to_annuity`, `income_per_person` | Q3: PTI is weak but interpretable and defensible to a regulator; the others are standard affordability ratios. |
| `ext_source_mean`, `_min`, `_max`, `_count` | Q1: the strongest predictors, but often missing (EXT_SOURCE_1 for 56.4%). Summaries use whatever scores exist. |
| `fields_missing` (count of blank fields per applicant) | Q6: default climbs from 6.1% with a complete record to 11.2% at 51+ blanks. |
| 18 `<column>_missing` indicator flags | §3.2 / Q6: impute, but keep the fact that a value was filled. A flag is added when a column's missing rows differ in default rate by at least 1 percentage point on train. Flags with identical missing patterns are de-duplicated. The flags are `EXT_SOURCE_1`, `EXT_SOURCE_3`, `OWN_CAR_AGE`, `TOTALAREA_MODE`, and 14 building `_AVG` columns. |
| Binned variables: `ltv_band`, `age_band`, `tenure_band` (with a "Not employed" level), `bureau_depth_band`, `fields_missing_band`, `pti_decile` | Q2, Q3, Q4: these relationships are U-shaped or bend, so a linear term misreads them. Q5, Q6, Q8: the band cutoffs are taken from the EDA plots. |
| Interaction terms: `ext_mean_x_age`, `ltv_x_pti`, `thin_file` (no bureau record **and** no inquiry data) | `ext_mean_x_age` combines the two strongest relationships (Q1, Q8). `ltv_x_pti` combines two affordability stress signals (Q3, Q4). `thin_file` joins the same thin-file signal that Q2 and Q9 found from two directions (41,519 train applicants). |

**Supplementary table: bureau.** `aggregate_bureau()` reduces 1.7 million bureau rows to one row per applicant. It builds 12 features: number of credits, active credits, credit types, years since first and last credit, active credit and debt totals, debt-to-credit, active share, overdue credits, maximum overdue amount, and prolongations. `join_bureau()` left-joins them onto the application table and adds `has_bureau_record` and `bureau_debt_to_income`. Following Q2, applicants with no bureau record get an explicit flag (they default at 10.1% vs 7.7%). Their counts and sums are set to 0, which is literally true, and their ratios are set to the train median, so a zero is never mistaken for "a few credits." §3.4 found no leakage in the bureau dates, so no rows are filtered out.

### EDA decisions not implemented

| Decision or finding | Why it is not in this script |
|---|---|
| Redundancy among the 47 building columns (AVG/MODE/MEDI triplets) | The EDA flagged this as untested. Removing columns is a feature-selection decision, so it is left to modeling, where a correlation check or regularization can make it. |
| Two-model approach (with and without external scores) | This is a modeling decision, not a preparation step. The script supports it: `drop_external_scores()` returns the restricted feature set (168 → 158 columns in test). |
| Age as a protected characteristic | Age is kept, because removing it is a policy call for the fairness review the EDA recommends. `age_years` and `age_band` are easy to drop there. |
| Class imbalance (8.1% positive) | A modeling decision, not a preparation step. Weighting and downsampling were tested in the modeling notebook (see [Modeling](#modeling)). |
| `bureau_balance`, `previous_application`, `POS_CASH_balance`, `installments_payments`, `credit_card_balance` | Not explored in the EDA, so there were no recorded decisions to implement. They are the natural next source of features. |
| `FLAG_WORK_PHONE` / `FLAG_PHONE` duplicate dictionary descriptions | Kept as-is. The data is valid; only the documentation is ambiguous. |

### Train/test consistency

Every value that is estimated from data is learned **from `application_train` only**, stored in `prep_params.rds`, and passed unchanged to the test call. `prepare_application()` runs the same steps in the same order for both files. It learns each parameter when `params = NULL` (train) and reuses it otherwise (test), so the two paths cannot drift apart.

| Parameter learned from train | Reused on test to… |
|---|---|
| Income cap: 99th percentile = **472,500** | cap test income at the same value |
| Missing-flag columns: the **18** columns listed above | create the same 18 flags, even if a column's test gap looks different |
| PTI decile cutoffs: 0.080, 0.104, 0.125, 0.144, 0.163, 0.186, 0.213, 0.247, 0.302 | place each test applicant where they would have fallen among training applicants |
| Medians for all **143** numeric features | fill test gaps, including columns that have no gaps in train |
| Kept levels and fallback for all **22** categorical columns | give test factors identical levels; any unseen test level maps to the train fallback |
| Final column list and order | select and order test columns to match train exactly |

The fixed LTV, age, tenure, bureau-depth, and missing-count bands come from the EDA plots rather than from either file, so they are identical by construction. Bureau aggregates use only each applicant's own rows, so nothing is shared across applicants or files.

`check_consistency()` runs at the end of every run and stops with an error if any check fails. Output from the latest run:

```
   check                                                passed
 1 Identical columns in identical order (except TARGET) TRUE
 2 TARGET present in train only                         TRUE
 3 Identical column types                               TRUE
 4 Identical factor levels                              TRUE
 5 One row per SK_ID_CURR in train                      TRUE
 6 One row per SK_ID_CURR in test                       TRUE
 7 Train row count unchanged by joins                   TRUE
 8 Test row count unchanged by joins                    TRUE
 9 No missing values in train                           TRUE
10 No missing values in test                            TRUE

Output dimensions
  train_prepared: 307511 rows x 169 columns
  test_prepared:  48744 rows x 168 columns
```

As a sanity check, the prepared training data reproduces the EDA's rates. No-bureau applicants default at 10.1% vs 7.7%. The LTV bands run from 5.1% (1.00–1.10) to 12.8% (above 1.30). The "Not employed" tenure band defaults at 5.4%.

### Use of AI

I wrote the script with Claude, using the decision table at the end of my EDA notebook as the specification. I checked the script by running it on the full data and confirming three things: every consistency check passed, the learned income cap matched the 99th percentile reported in the EDA, and the prepared data reproduced the EDA's default rates (above). Choices that required judgment were mine, drawing on EDA findings: folding XNA gender into the majority level rather than keeping a 4-row "Other," setting counts to 0 but ratios to the median for applicants with no bureau record, and de-duplicating the building-column missing flags.

---

## Modeling

[`homecredit-eda/modeling.qmd`](homecredit-eda/modeling.qmd) ([rendered](homecredit-eda/modeling.html)) builds a model that predicts each applicant's probability of payment difficulty (`TARGET = 1`). The aim is to **rank** applicants by risk, so ROC AUC is the primary metric throughout. Only 8.07% of applicants default, so a majority-class benchmark reaches 91.93% accuracy with an AUC of only 0.50.

### Approach

1. **Internal holdout.** The labeled data were split once into 80% development data and a 20% holdout, stratified on `TARGET`. The holdout was not touched until the final model had been chosen.
2. **Candidate models.** Ridge logistic regression, random forest, and XGBoost were compared on one stratified 50,001-row development sample, using identical stratified 3-fold CV folds and ROC AUC.
3. **Class imbalance.** XGBoost was compared with no adjustment, positive-class weighting, and random downsampling, with sampling applied inside each training fold only.
4. **Tuning.** A randomized search scored 20 XGBoost configurations with stratified 3-fold CV on a 5,000-row development sample.
5. **Final evaluation.** The selected model was fit on all development data and evaluated once on the holdout.
6. **Kaggle submission.** The model was then refit on all 307,511 labeled rows to predict the Kaggle test set.

### Results

| Model / experiment | ROC AUC | Evaluated on |
|---|---|---|
| Majority-class baseline | 0.5000 | Training data |
| Ridge logistic regression | 0.7473 | 3-fold CV, exploration sample |
| Random forest | 0.7262 | 3-fold CV, exploration sample |
| XGBoost (initial, unadjusted) | **0.7575** | 3-fold CV, exploration sample |
| XGBoost, positive-class weighting | 0.7514 | 3-fold CV, exploration sample |
| XGBoost, random downsampling | 0.7495 | 3-fold CV, exploration sample |
| Final XGBoost: untouched holdout | **0.7556** | 61,502 holdout applicants |
| Final XGBoost: Kaggle public | **0.75749** | Kaggle test set (public portion) |
| Final XGBoost: Kaggle private | **0.75276** | Kaggle test set (private portion) |

These numbers come from different evaluation datasets, not one identical experiment:
- The first six rows are mean cross-validated AUCs on the same 50,001-row development sample and folds, so they can be compared with each other.
- The holdout AUC comes from a model trained on all development data and scored on unseen labeled applicants.
- The Kaggle scores come from the same specification refit on all labeled data. They were obtained as a late submission after the competition closed.

### Model choice

**XGBoost was selected** for three reasons. It had the highest cross-validated AUC of the three candidate models, it led in every fold, and it was the fastest to fit.
- **Imbalance.** Weighting and downsampling raised sensitivity at a 0.50 threshold but lowered AUC, so the unadjusted model was kept.
- **Tuning.** The randomized search chose shallow, slowly learning, regularized trees: `nrounds = 300`, `max_depth = 2`, `eta = 0.047`, `gamma = 4`, `colsample_bytree = 0.95`, `min_child_weight = 10`, `subsample = 0.86`. The best tuning-sample CV AUC (0.7085) comes from a much smaller sample and is not comparable with the other rows.
- **Overfitting.** In-sample AUC was 0.7639 against 0.7556 on the holdout, a gap of 0.0083. Together with Kaggle scores close to the holdout estimate, this shows limited evidence of overfitting.

### Findings

- **Uses.** The model ranks applicants by estimated risk well above chance. It could help prioritize applications for review, focus underwriting resources, and flag applicants for extra verification. It should support lending decisions, not make them automatically.
- **Drivers.** External-score features dominate the model's predictions. Loan structure, bureau history, and employment stability also contribute. These are predictive associations, not causes.
- **Fairness.** Age and gender are among the influential predictors, so a fairness review and a legal and compliance review would be needed before any real use.

### Limitations

- **Possible optimism.** Some feature choices and missing-value flags used `TARGET` on the full training data, holdout rows included, before CV. CV and holdout estimates may therefore be slightly optimistic. The Kaggle scores, whose outcomes were never used, suggest the effect is small.
- **Unused tables.** Only `bureau` was used among the supplementary tables.
- **Noisy tuning.** The tuning sample had only 404 defaults.
- **No decision analysis.** No decision threshold or cost-benefit analysis was done.

### How to run

The prepared files from `data_preparation.R` must exist first. Then render the notebook from `homecredit-eda/`:

```
quarto render modeling.qmd
```

- **Packages:** `tidyverse`, `caret`, `glmnet`, `randomForest`, `xgboost` (3.x), `pROC`, and `doParallel`.
- **Compatibility fix:** caret 7.0.1's built-in `xgbTree` method is incompatible with xgboost 3.x, so the notebook defines a small compatible copy of it.
- **Runtime:** a full render refits every model and takes roughly 10 minutes.
- **Outputs:** it writes the final model to `models/final_home_credit_xgb.rds` and the submission to `submissions/home_credit_xgboost_submission.csv`. Both folders are git-ignored.
