# =============================================================================
# data_preparation.R
# Home Credit Default Risk: data preparation
# Author: Jake Hoopes
#
# Turns the decisions recorded in homecredit-eda/eda.qmd into reusable
# functions that clean the application tables, engineer features, aggregate
# the bureau table, and join everything into one modeling table per applicant.
#
# The central rule is train/test consistency. Anything estimated from data
# (the income cap, imputation medians, payment-to-income decile cutoffs,
# category levels, and which columns get a missing-value flag) is learned from
# application_train only, stored in a `params` list, and reused unchanged on
# application_test. The test file never influences its own transformation,
# which is what prevents leakage.
#
# Usage, from the repository root:
#   Rscript data_preparation.R
# or interactively:
#   source("data_preparation.R")
#   result <- run_data_preparation()
#
# Comments tagged "EDA:" name the section of eda.qmd whose decision a
# transformation implements.
# =============================================================================

suppressPackageStartupMessages(library(tidyverse))


# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

# EDA 3.3 / Q5: 365243 days is 1,000 years, a placeholder rather than a
# measurement. 55,352 of the 55,374 rows carrying it are pensioners.
DAYS_EMPLOYED_SENTINEL <- 365243

DAYS_PER_YEAR <- 365.25

# EDA Q3: incomes above the 99th percentile are not credible (max 117 million
# against a 147,150 median), so they are capped at this quantile of train.
INCOME_CAP_QUANTILE <- 0.99

# EDA 3.2: a numeric column gets a companion missing flag when its missing
# rows default at a rate at least 1 percentage point different from its
# present rows. The share floor stops flags on a handful of blank rows.
MISSING_FLAG_MIN_GAP   <- 0.01
MISSING_FLAG_MIN_SHARE <- 0.005

# EDA Q7 / 3.5: categorical levels with fewer than this many training rows are
# too small to trust (Maternity leave had 5 applicants and a 40% default rate).
RARE_LEVEL_MIN_COUNT <- 50

# EDA Q9: the six bureau inquiry counts were weak (best correlation +0.02) and
# the one-month window ran backwards. They are replaced by one flag.
INQUIRY_COLS <- c("AMT_REQ_CREDIT_BUREAU_HOUR", "AMT_REQ_CREDIT_BUREAU_DAY",
                  "AMT_REQ_CREDIT_BUREAU_WEEK", "AMT_REQ_CREDIT_BUREAU_MON",
                  "AMT_REQ_CREDIT_BUREAU_QRT",  "AMT_REQ_CREDIT_BUREAU_YEAR")

# Fixed bands taken from the EDA plots. These are domain cutoffs read off the
# shape of each default-rate curve, not quantiles, so they do not depend on
# either file. Outer edges are open so a test value outside the train range
# still lands in a band.
LTV_BREAKS <- c(-Inf, 1, 1.1, 1.2, 1.3, Inf)                        # EDA Q4
LTV_LABELS <- c("1.00 or below", "1.00 to 1.10", "1.10 to 1.20",
                "1.20 to 1.30", "Above 1.30")

AGE_BREAKS <- c(-Inf, 25, 30, 40, 50, 60, Inf)                     # EDA Q8
AGE_LABELS <- c("Under 25", "25 to 30", "30 to 40", "40 to 50",
                "50 to 60", "60 and over")

TENURE_BREAKS <- c(-Inf, 1, 3, 5, 10, Inf)                          # EDA Q5
TENURE_LABELS <- c("Under 1", "1 to 3", "3 to 5", "5 to 10", "10 or more")

BUREAU_DEPTH_BREAKS <- c(-Inf, 0, 2, 5, 10, Inf)                    # EDA Q2
BUREAU_DEPTH_LABELS <- c("None", "1 to 2", "3 to 5", "6 to 10", "11 or more")

FIELDS_MISSING_BREAKS <- c(-Inf, 0, 10, 30, 50, Inf)                # EDA Q6
FIELDS_MISSING_LABELS <- c("0", "1 to 10", "11 to 30", "31 to 50", "51 or more")


# -----------------------------------------------------------------------------
# Small helpers
# -----------------------------------------------------------------------------

#' Divide two vectors, returning NA instead of Inf or NaN when the denominator
#' is zero or missing. Ratios feed imputation later, and Inf would survive it.
safe_divide <- function(num, den) {
  if_else(is.na(den) | den == 0, NA_real_, num / den)
}

#' Maximum that returns NA for an all-missing group instead of -Inf.
max_or_na <- function(x) {
  if (all(is.na(x))) NA_real_ else max(x, na.rm = TRUE)
}


# -----------------------------------------------------------------------------
# 1. Loading
# -----------------------------------------------------------------------------

#' Read the three raw tables this script uses.
#'
#' application_test is read with the column types detected in
#' application_train, so a column cannot come in as numeric in one file and
#' character in the other just because of what the first rows happened to hold.
#'
#' @param data_dir Folder containing the Kaggle CSV files.
#' @return A list with elements train, test, and bureau.
load_raw_data <- function(data_dir) {
  train <- read_csv(file.path(data_dir, "application_train.csv"),
                    guess_max = 50000, show_col_types = FALSE)

  train_types <- spec(train)$cols
  train_types$TARGET <- NULL
  test <- read_csv(file.path(data_dir, "application_test.csv"),
                   col_types = do.call(cols, train_types))

  bureau <- read_csv(file.path(data_dir, "bureau.csv"),
                     guess_max = 50000, show_col_types = FALSE)

  list(train = train, test = test, bureau = bureau)
}


# -----------------------------------------------------------------------------
# 2. Cleaning the application table (no learned parameters)
# -----------------------------------------------------------------------------

#' Fix the data problems EDA found in the application table.
#'
#' Nothing here is estimated from data, so this step is identical for train
#' and test by construction.
#'
#' @param app A raw application_train or application_test tibble.
#' @return The cleaned tibble, with three new columns and seven fewer.
clean_application <- function(app) {
  app |>
    mutate(
      # EDA Q6: count blank fields before any recoding, so the count reflects
      # what the applicant actually supplied. Default rate climbed from 6.1%
      # with a complete record to 11.2% with 51+ blanks.
      fields_missing = rowSums(is.na(pick(-any_of(c("SK_ID_CURR", "TARGET"))))),

      # EDA Q9: the six inquiry columns are blank together for 13.5% of
      # applicants, who default at 10.3% against 7.7%. Whether the block exists
      # is the useful signal, not the counts inside it.
      no_inquiry_data = as.integer(if_all(all_of(INQUIRY_COLS), is.na)),

      # EDA Q5: the sentinel marks a category (mostly pensioners, 5.4% default
      # against 8.7%), so it becomes a flag, and the tenure column goes to NA
      # so the sentinel cannot drag its mean to 63,815 days.
      not_currently_employed = as.integer(DAYS_EMPLOYED == DAYS_EMPLOYED_SENTINEL),
      DAYS_EMPLOYED = na_if(DAYS_EMPLOYED, DAYS_EMPLOYED_SENTINEL)
    ) |>
    # EDA Q9: raw inquiry counts are dropped in favor of the flag above.
    # EDA 3.3: FLAG_MOBIL is 0 for exactly one applicant, so it has no variance
    # to learn from.
    select(-all_of(INQUIRY_COLS), -FLAG_MOBIL)
}


#' Learn the income cap from training data.
#' @return A single number, the 99th percentile of AMT_INCOME_TOTAL in train.
learn_income_cap <- function(app) {
  unname(quantile(app$AMT_INCOME_TOTAL, INCOME_CAP_QUANTILE, na.rm = TRUE))
}

#' Cap reported income at the learned value.
#'
#' EDA Q3: capped rather than deleted, because the rest of those applications
#' look normal. Capping happens before any ratio is built from income, so the
#' ratios inherit the correction.
cap_income <- function(app, income_cap) {
  app |> mutate(AMT_INCOME_TOTAL = pmin(AMT_INCOME_TOTAL, income_cap))
}


# -----------------------------------------------------------------------------
# 3. Feature engineering (no learned parameters)
# -----------------------------------------------------------------------------

#' Build demographic, financial-ratio, and external-score features.
#'
#' @param app A cleaned, income-capped application tibble.
#' @return The tibble with engineered features added and the raw DAYS_ columns
#'   they replace removed.
engineer_features <- function(app) {
  app |>
    mutate(
      # Demographics. DAYS_ columns count days before the application, so they
      # are negative. Flipping the sign and converting to years makes them
      # readable. EDA Q8: default fell from 12.3% at 20-25 to 4.9% at 60-70.
      # EDA Q5: from 11.0% under one year employed to 5.2% at ten or more.
      age_years                = -DAYS_BIRTH / DAYS_PER_YEAR,
      years_employed           = -DAYS_EMPLOYED / DAYS_PER_YEAR,
      years_since_registration = -DAYS_REGISTRATION / DAYS_PER_YEAR,
      years_since_id_publish   = -DAYS_ID_PUBLISH / DAYS_PER_YEAR,
      years_since_phone_change = -DAYS_LAST_PHONE_CHANGE / DAYS_PER_YEAR,

      # Share of adult life spent in the current job. Age and tenure both
      # measure stability (EDA Q8), and this ratio separates a young applicant
      # with a short job from an older one who just changed jobs.
      employed_share_of_life = safe_divide(years_employed, age_years),

      # Financial ratios.
      # EDA Q4: loan-to-value. 5.1% default at 1.00-1.10 rising to 12.8% above
      # 1.30. Values above 1 are financed fees, not errors (EDA 3.3).
      ltv = safe_divide(AMT_CREDIT, AMT_GOODS_PRICE),
      # EDA Q3: payment-to-income is weak but interpretable and defensible to
      # a regulator, so it is kept.
      pti = safe_divide(AMT_ANNUITY, AMT_INCOME_TOTAL),
      credit_to_income  = safe_divide(AMT_CREDIT, AMT_INCOME_TOTAL),
      # Number of payments needed to repay the loan, a proxy for loan term.
      credit_to_annuity = safe_divide(AMT_CREDIT, AMT_ANNUITY),
      income_per_person = safe_divide(AMT_INCOME_TOTAL, CNT_FAM_MEMBERS),

      # EDA Q1: the external scores are the strongest columns in the file but
      # are often missing (EXT_SOURCE_1 for 56.4%). Summaries across the three
      # use whatever scores an applicant has, and the count records how many.
      ext_source_mean  = rowMeans(pick(EXT_SOURCE_1, EXT_SOURCE_2, EXT_SOURCE_3),
                                  na.rm = TRUE),
      ext_source_mean  = if_else(is.nan(ext_source_mean), NA_real_, ext_source_mean),
      ext_source_min   = pmin(EXT_SOURCE_1, EXT_SOURCE_2, EXT_SOURCE_3, na.rm = TRUE),
      ext_source_max   = pmax(EXT_SOURCE_1, EXT_SOURCE_2, EXT_SOURCE_3, na.rm = TRUE),
      ext_source_count = rowSums(!is.na(pick(EXT_SOURCE_1, EXT_SOURCE_2, EXT_SOURCE_3)))
    ) |>
    # The year versions above carry the same information in readable units.
    select(-DAYS_BIRTH, -DAYS_EMPLOYED, -DAYS_REGISTRATION,
           -DAYS_ID_PUBLISH, -DAYS_LAST_PHONE_CHANGE)
}


# -----------------------------------------------------------------------------
# 4. Supplementary table: bureau
# -----------------------------------------------------------------------------

#' Aggregate bureau.csv to one row per applicant.
#'
#' bureau holds one row per prior credit, a median of 4 per applicant (EDA 2.2).
#' It covers train and test applicants alike and each summary uses only that
#' applicant's own rows, so no parameters are learned here and no information
#' crosses between applicants or files.
#'
#' EDA 3.4: temporal checks came back clean (zero DAYS_ENDDATE_FACT values
#' after the application date), so no rows are filtered out.
#'
#' @param bureau The raw bureau tibble.
#' @return A tibble keyed on SK_ID_CURR, one row per applicant with bureau history.
aggregate_bureau <- function(bureau) {
  bureau |>
    group_by(SK_ID_CURR) |>
    summarise(
      # EDA Q2: depth of history, which relates to default in a U shape.
      bureau_credits        = n(),
      bureau_active_credits = sum(CREDIT_ACTIVE == "Active"),
      bureau_credit_types   = n_distinct(CREDIT_TYPE),

      # Recency and length of credit history, in years before the application.
      bureau_years_since_last_credit  = -max(DAYS_CREDIT) / DAYS_PER_YEAR,
      bureau_years_since_first_credit = -min(DAYS_CREDIT) / DAYS_PER_YEAR,

      # Current leverage, on open credits only, since closed debt is repaid.
      bureau_active_credit_sum = sum(AMT_CREDIT_SUM[CREDIT_ACTIVE == "Active"],
                                     na.rm = TRUE),
      bureau_active_debt_sum   = sum(AMT_CREDIT_SUM_DEBT[CREDIT_ACTIVE == "Active"],
                                     na.rm = TRUE),

      # Past repayment trouble reported by other lenders.
      bureau_overdue_credits    = sum(CREDIT_DAY_OVERDUE > 0, na.rm = TRUE),
      bureau_max_overdue_amount = max_or_na(AMT_CREDIT_MAX_OVERDUE),
      bureau_prolongations      = sum(CNT_CREDIT_PROLONG, na.rm = TRUE),
      .groups = "drop"
    ) |>
    mutate(
      bureau_active_share   = bureau_active_credits / bureau_credits,
      bureau_debt_to_credit = safe_divide(bureau_active_debt_sum,
                                          bureau_active_credit_sum)
    )
}

#' Join aggregated bureau features onto an application table.
#'
#' EDA Q2: the 14.3% of applicants with no bureau record default at 10.1%
#' against 7.7%. The EDA decision was an explicit flag rather than imputing
#' zero, because zero credits and a few credits sit at opposite ends of the
#' risk curve. So:
#'   * has_bureau_record carries the "no history" signal directly.
#'   * Counts and sums become 0 for no-record applicants, which is literally
#'     true (they have no reported credits or debt). The flag keeps the model
#'     from reading that 0 as ordinary low usage.
#'   * Ratios and recency stay NA here and get the train median at the
#'     imputation step, since "years since last credit" has no true value
#'     for someone with no credit.
#'
#' @param app An application tibble after engineer_features().
#' @param bureau_agg Output of aggregate_bureau().
#' @return app with bureau features and two flags added, same row count.
join_bureau <- function(app, bureau_agg) {
  count_cols <- c("bureau_credits", "bureau_active_credits", "bureau_credit_types",
                  "bureau_active_credit_sum", "bureau_active_debt_sum",
                  "bureau_overdue_credits", "bureau_prolongations")

  app |>
    left_join(bureau_agg, by = "SK_ID_CURR") |>
    mutate(
      has_bureau_record = as.integer(!is.na(bureau_credits)),
      across(all_of(count_cols), ~ replace_na(.x, 0)),

      # Outstanding bureau debt relative to (capped) income.
      bureau_debt_to_income = safe_divide(bureau_active_debt_sum, AMT_INCOME_TOTAL),

      # Interaction term. EDA Q2 and Q9 surfaced the same thin-file signal
      # from two directions (no bureau record; no inquiry data). An applicant
      # missing both is the thinnest file the lender sees.
      thin_file = as.integer(has_bureau_record == 0 & no_inquiry_data == 1)
    )
}


# -----------------------------------------------------------------------------
# 5. Missing-value indicators (learned: which columns get a flag)
# -----------------------------------------------------------------------------

#' Choose which numeric columns get a companion missing flag.
#'
#' EDA 3.2: missingness is informative (EXT_SOURCE_3 missing: 9.3% default
#' against 7.8%), so imputing alone would erase signal. A flag is added for
#' each column whose missing rows default at a rate at least
#' MISSING_FLAG_MIN_GAP away from its present rows, measured on train only.
#'
#' The 47 building columns tend to go missing together, which would produce
#' dozens of identical flags. Candidates are ranked by gap and a flag is
#' skipped when its missing pattern exactly matches one already kept.
#'
#' Excluded from candidacy:
#'   * bureau_ columns, whose missingness is has_bureau_record.
#'   * years_employed and employed_share_of_life, whose missingness is
#'     not_currently_employed.
#'   * Categorical columns, which get an explicit "Missing" level instead.
#'
#' @param app Training data after join_bureau(). Must contain TARGET.
#' @return Character vector of column names to flag.
learn_missing_flag_cols <- function(app) {
  candidates <- app |>
    select(where(is.numeric),
           -any_of(c("SK_ID_CURR", "TARGET", "years_employed",
                     "employed_share_of_life")),
           -starts_with("bureau_", ignore.case = FALSE)) |>
    names()

  gaps <- candidates |>
    map(function(col) {
      is_missing <- is.na(app[[col]])
      share <- mean(is_missing)
      if (share < MISSING_FLAG_MIN_SHARE || share == 1) return(NULL)
      tibble(column = col,
             gap    = abs(mean(app$TARGET[is_missing]) -
                          mean(app$TARGET[!is_missing])))
    }) |>
    list_rbind() |>
    filter(gap >= MISSING_FLAG_MIN_GAP) |>
    arrange(desc(gap))

  # Keep a flag only if its pattern of missing rows is new.
  kept <- character(0)
  kept_patterns <- list()
  for (col in gaps$column) {
    pattern <- is.na(app[[col]])
    if (!any(map_lgl(kept_patterns, identical, pattern))) {
      kept <- c(kept, col)
      kept_patterns <- c(kept_patterns, list(pattern))
    }
  }
  kept
}

#' Add a 0/1 "<column>_missing" flag for each selected column.
#' Must run before imputation, while the NAs are still visible.
add_missing_flags <- function(app, flag_cols) {
  app |>
    mutate(across(all_of(flag_cols), ~ as.integer(is.na(.x)),
                  .names = "{.col}_missing"))
}


# -----------------------------------------------------------------------------
# 6. Binned variables (learned: payment-to-income decile cutoffs)
# -----------------------------------------------------------------------------

#' Learn payment-to-income decile cutoffs from train.
#'
#' EDA Q3 analysed PTI by decile and found the relationship is not monotonic
#' (it falls back in the top decile), so bands let a model capture that shape.
#' The cutoffs come from train and are reused on test, so a test applicant is
#' placed by where they would have fallen among training applicants.
#'
#' @return Numeric vector of 11 break points with open outer edges.
learn_pti_breaks <- function(app) {
  breaks <- quantile(app$pti, probs = seq(0, 1, 0.1), na.rm = TRUE, names = FALSE)
  breaks[1] <- -Inf
  breaks[length(breaks)] <- Inf
  unique(breaks)
}

#' Add banded versions of features whose relationship with default is not
#' linear, so a linear model can use them and the bands are easy to explain.
#'
#' Bands are created as character columns. A missing input gives NA, which the
#' categorical step turns into its own "Missing" level.
#'
#' @param app Data after add_missing_flags().
#' @param pti_breaks Output of learn_pti_breaks(), from train.
add_bins <- function(app, pti_breaks) {
  app |>
    mutate(
      # EDA Q4: dip at 1.00-1.10 then steady climb, so a straight line misreads it.
      ltv_band = as.character(cut(ltv, LTV_BREAKS, LTV_LABELS)),
      # EDA Q8: steeper drop between the first two age bands than elsewhere.
      age_band = as.character(cut(age_years, AGE_BREAKS, AGE_LABELS)),
      # EDA Q5: the not-employed group is its own low-risk category, so it gets
      # its own band rather than sitting in the tenure scale.
      tenure_band = if_else(not_currently_employed == 1, "Not employed",
                            as.character(cut(years_employed, TENURE_BREAKS,
                                             TENURE_LABELS))),
      # EDA Q2: U-shaped, so bands rather than a linear count.
      bureau_depth_band = as.character(cut(bureau_credits, BUREAU_DEPTH_BREAKS,
                                           BUREAU_DEPTH_LABELS)),
      # EDA Q6: default rate rises at every step of this banding.
      fields_missing_band = as.character(cut(fields_missing, FIELDS_MISSING_BREAKS,
                                             FIELDS_MISSING_LABELS)),
      # EDA Q3: deciles with cutoffs learned from train.
      pti_decile = as.character(cut(pti, pti_breaks,
                                    labels = paste0("D", seq_len(length(pti_breaks) - 1))))
    )
}


# -----------------------------------------------------------------------------
# 7. Imputation (learned: medians)
# -----------------------------------------------------------------------------

#' Learn the median of every numeric feature from train.
#'
#' EDA 3.2: never drop rows, since the rows with gaps are the riskiest.
#' Medians rather than means because income, credit amounts and ratios are
#' heavily right-skewed. Medians are learned for every numeric column, not
#' only those with gaps in train, so a test-only gap still has a fill value.
#'
#' @return Named list of medians.
learn_medians <- function(app) {
  app |>
    select(where(is.numeric), -any_of(c("SK_ID_CURR", "TARGET"))) |>
    map(~ median(.x, na.rm = TRUE))
}

#' Fill numeric NAs with the train medians.
#'
#' All numeric features are converted to double first. Otherwise an integer
#' column filled with a fractional median would become double in one file and
#' stay integer in the other.
impute_numeric <- function(app, medians) {
  app |>
    mutate(across(all_of(names(medians)),
                  ~ replace_na(as.double(.x), medians[[cur_column()]])))
}


# -----------------------------------------------------------------------------
# 8. Categorical levels (learned: levels to keep and where rare ones go)
# -----------------------------------------------------------------------------

#' Learn the levels to keep for each categorical column from train.
#'
#' EDA 3.5 / Q7: levels with tiny counts (XNA gender: 4, Maternity leave: 5,
#' Unknown family status: 2, Unemployed: 22) produce unreliable default rates
#' and, when they never occur in test, all-zero dummy columns.
#'   * NA becomes an explicit "Missing" level. EDA 3.2 showed missing
#'     OCCUPATION_TYPE is informative (mostly pensioners, 6.5% default).
#'   * Levels under RARE_LEVEL_MIN_COUNT are pooled into "Other".
#'   * If the pooled "Other" would itself be rare, rare levels fold into the
#'     most common level instead (the EDA's "fold into the majority" option).
#'     This is what happens to XNA gender.
#'   * Any level in test that train never saw goes to the same fallback.
#'
#' @return Named list; each element has `levels` (final factor levels) and
#'   `fallback` (where rare or unseen values go).
learn_category_levels <- function(app) {
  app |>
    select(where(is.character)) |>
    map(function(x) {
      counts <- table(replace_na(x, "Missing"))
      common <- names(counts)[counts >= RARE_LEVEL_MIN_COUNT]
      rare_total <- sum(counts[counts < RARE_LEVEL_MIN_COUNT])

      fallback <- if (rare_total >= RARE_LEVEL_MIN_COUNT) "Other"
                  else names(counts)[which.max(counts)]
      list(levels = unique(c(common, fallback)), fallback = fallback)
    })
}

#' Apply the learned levels, turning every categorical column into a factor
#' with exactly the same levels in train and test.
encode_categories <- function(app, category_levels) {
  app |>
    mutate(across(all_of(names(category_levels)), function(x) {
      spec <- category_levels[[cur_column()]]
      x <- replace_na(x, "Missing")
      x <- if_else(x %in% spec$levels, x, spec$fallback)
      factor(x, levels = spec$levels)
    }))
}


# -----------------------------------------------------------------------------
# 9. Interaction terms (no learned parameters)
# -----------------------------------------------------------------------------

#' Add interaction terms. Runs after imputation so no product is NA.
#' (thin_file, the third interaction, is built in join_bureau().)
add_interactions <- function(app) {
  app |>
    mutate(
      # EDA Q1 and Q8: the two strongest relationships in the file. A low
      # score in a young applicant is a sharper warning than either alone.
      ext_mean_x_age = ext_source_mean * age_years,
      # EDA Q3 and Q4: financing everything (high LTV) while also carrying a
      # heavy payment burden (high PTI) is a compound stress signal.
      ltv_x_pti = ltv * pti
    )
}


# -----------------------------------------------------------------------------
# 10. The full pipeline
# -----------------------------------------------------------------------------

#' Put columns in the order recorded from train, so train and test match
#' column for column. TARGET sits second when present.
order_columns <- function(app, feature_cols) {
  missing_cols <- setdiff(feature_cols, names(app))
  if (length(missing_cols) > 0) {
    stop("Columns expected from train are absent: ",
         paste(missing_cols, collapse = ", "))
  }
  app |> select(SK_ID_CURR, any_of("TARGET"), all_of(feature_cols))
}

#' Prepare an application table for modeling.
#'
#' Call once on train with params = NULL to learn and return the parameters,
#' then again on test passing those parameters. Both calls run the same steps
#' in the same order, which is what guarantees identical transformations.
#'
#' @param app_raw Raw application_train or application_test tibble.
#' @param bureau_agg Output of aggregate_bureau().
#' @param params NULL to fit on this data (train only), or the params list
#'   returned by the train call.
#' @return list(data = prepared tibble, params = learned parameters).
prepare_application <- function(app_raw, bureau_agg, params = NULL) {
  fitting <- is.null(params)
  if (fitting) {
    if (!"TARGET" %in% names(app_raw)) {
      stop("Parameters must be learned from training data (TARGET not found).")
    }
    params <- list()
  }

  app <- clean_application(app_raw)

  if (fitting) params$income_cap <- learn_income_cap(app)
  app <- cap_income(app, params$income_cap)

  app <- engineer_features(app)
  app <- join_bureau(app, bureau_agg)

  if (fitting) params$missing_flag_cols <- learn_missing_flag_cols(app)
  app <- add_missing_flags(app, params$missing_flag_cols)

  if (fitting) params$pti_breaks <- learn_pti_breaks(app)
  app <- add_bins(app, params$pti_breaks)

  if (fitting) params$medians <- learn_medians(app)
  app <- impute_numeric(app, params$medians)

  if (fitting) params$category_levels <- learn_category_levels(app)
  app <- encode_categories(app, params$category_levels)

  app <- add_interactions(app)

  if (fitting) params$feature_cols <- setdiff(names(app), c("SK_ID_CURR", "TARGET"))
  app <- order_columns(app, params$feature_cols)

  list(data = app, params = params)
}

#' Remove the external credit scores and everything derived from them.
#'
#' EDA conclusions: the recommended approach is two models, a full one that
#' sets the performance ceiling and a restricted one built on interpretable
#' features that can be explained to a declined applicant. This returns the
#' input for the restricted model from either prepared table.
drop_external_scores <- function(prepared) {
  prepared |>
    select(-starts_with("EXT_SOURCE"),      # case-insensitive: also ext_source_*
           -any_of("ext_mean_x_age"))
}


# -----------------------------------------------------------------------------
# 11. Consistency checks
# -----------------------------------------------------------------------------

#' Verify train and test came out consistent. Stops with an error if any check
#' fails, so a broken run cannot silently write output.
#'
#' @return A tibble of checks and whether each passed.
check_consistency <- function(train_prep, test_prep, train_raw, test_raw) {
  train_features <- setdiff(names(train_prep), "TARGET")
  col_types <- function(df) map_chr(df, ~ class(.x)[1])
  factor_levels <- function(df) map(select(df, where(is.factor)), levels)

  checks <- tribble(
    ~check, ~passed,
    "Identical columns in identical order (except TARGET)",
      identical(train_features, names(test_prep)),
    "TARGET present in train only",
      "TARGET" %in% names(train_prep) && !"TARGET" %in% names(test_prep),
    "Identical column types",
      identical(col_types(train_prep)[train_features], col_types(test_prep)),
    "Identical factor levels",
      identical(factor_levels(train_prep), factor_levels(test_prep)),
    "One row per SK_ID_CURR in train",
      !anyDuplicated(train_prep$SK_ID_CURR),
    "One row per SK_ID_CURR in test",
      !anyDuplicated(test_prep$SK_ID_CURR),
    "Train row count unchanged by joins",
      nrow(train_prep) == nrow(train_raw),
    "Test row count unchanged by joins",
      nrow(test_prep) == nrow(test_raw),
    "No missing values in train",
      !anyNA(train_prep),
    "No missing values in test",
      !anyNA(test_prep)
  )

  print(checks, n = Inf)
  if (!all(checks$passed)) stop("Train/test consistency checks failed.")
  checks
}


# -----------------------------------------------------------------------------
# 12. Entry point
# -----------------------------------------------------------------------------

#' Run the whole preparation and write outputs.
#'
#' @param data_dir Folder holding the raw Kaggle CSVs.
#' @param out_dir Folder for outputs. It sits inside the git-ignored data
#'   folder so nothing large is committed.
#' @return Invisibly, a list with train, test, params, and checks.
run_data_preparation <- function(data_dir = "homecredit-eda/data",
                                 out_dir  = file.path(data_dir, "prepared")) {
  message("Reading raw data from ", data_dir)
  raw <- load_raw_data(data_dir)

  message("Aggregating bureau")
  bureau_agg <- aggregate_bureau(raw$bureau)

  message("Preparing train (learning parameters)")
  train_result <- prepare_application(raw$train, bureau_agg)

  message("Preparing test (reusing train parameters)")
  test_result <- prepare_application(raw$test, bureau_agg,
                                     params = train_result$params)

  message("Checking train/test consistency")
  checks <- check_consistency(train_result$data, test_result$data,
                              raw$train, raw$test)

  cat("\nOutput dimensions\n")
  cat("  train_prepared:", nrow(train_result$data), "rows x",
      ncol(train_result$data), "columns\n")
  cat("  test_prepared: ", nrow(test_result$data), "rows x",
      ncol(test_result$data), "columns\n")

  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  saveRDS(train_result$data,   file.path(out_dir, "train_prepared.rds"))
  saveRDS(test_result$data,    file.path(out_dir, "test_prepared.rds"))
  saveRDS(train_result$params, file.path(out_dir, "prep_params.rds"))
  message("Wrote outputs to ", out_dir)

  invisible(list(train  = train_result$data,
                 test   = test_result$data,
                 params = train_result$params,
                 checks = checks))
}

# Run the pipeline only when executed as a script (Rscript data_preparation.R),
# not when sourced to reuse the functions.
if (sys.nframe() == 0) {
  run_data_preparation()
}
