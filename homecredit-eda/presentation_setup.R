# presentation_setup.R
# Shared setup for 01_business_impact.Rmd and 02_personas.Rmd.
#
# Loads the model objects the presentation needs: the final XGBoost model fit
# on the development data (final_internal_xgb), the 61,502-row holdout, and
# the holdout predictions. These are the exact objects modeling.qmd creates.
#
# The first run rebuilds them by running modeling.qmd's own code (about 10
# minutes, same as a render) and caches them in presentation_cache/. Every
# later run loads the cache in seconds.
#
# Expects to run from homecredit-eda/, next to modeling.qmd.

suppressPackageStartupMessages({
  library(tidyverse)
  library(caret)
  library(xgboost)
  library(pROC)
})

cache_dir  <- "presentation_cache"
cache_path <- file.path(cache_dir, "model_objects.rds")
results_dir <- "presentation_results"
dir.create(results_dir, showWarnings = FALSE)

if (file.exists(cache_path)) {
  obj <- readRDS(cache_path)
} else {
  stopifnot("Run from homecredit-eda/ (modeling.qmd not found)" = file.exists("modeling.qmd"))
  message("No cache yet: running modeling.qmd's code once (about 10 minutes)...")
  # knitr extracts the R chunks from a copy of the notebook; the notebook
  # itself is not changed.
  tmp_rmd <- tempfile(fileext = ".Rmd")
  tmp_r   <- tempfile(fileext = ".R")
  file.copy("modeling.qmd", tmp_rmd)
  knitr::purl(tmp_rmd, output = tmp_r, quiet = TRUE, documentation = 0)
  modeling_env <- new.env()
  source(tmp_r, local = modeling_env)
  obj <- list(
    final_internal_xgb = modeling_env$final_internal_xgb,
    holdout_data       = modeling_env$holdout_data,
    holdout_prob       = modeling_env$holdout_prob,
    holdout_auc        = modeling_env$holdout_auc
  )
  dir.create(cache_dir, showWarnings = FALSE)
  saveRDS(obj, cache_path)
  rm(modeling_env)
}

final_internal_xgb <- obj$final_internal_xgb
holdout_data       <- obj$holdout_data
holdout_prob       <- obj$holdout_prob

# Sanity check: the cached predictions must reproduce the reported holdout AUC.
check_auc <- as.numeric(auc(holdout_data$TARGET, holdout_prob,
                            levels = c(0, 1), direction = "<", quiet = TRUE))
message(sprintf("Holdout AUC check: %.4f (modeling.qmd reported 0.7556)", check_auc))

pct <- function(x, d = 1) scales::percent(x, accuracy = 10^-d)
num <- function(x) scales::comma(round(x))

# Per-applicant explanations ---------------------------------------------------
# XGBoost can split every prediction into one contribution per model column
# (SHAP values, on the log-odds scale). They add up exactly to the prediction,
# so they say how much each piece of an application pushed the risk up or down.
# The model matrix is rebuilt the same way caret's predict() builds it.
explain_applicants <- function(fit, newdata) {
  terms_x <- delete.response(fit$terms)
  mf <- model.frame(terms_x, newdata, na.action = na.pass, xlev = fit$xlevels)
  x  <- model.matrix(terms_x, mf, contrasts.arg = fit$contrasts)
  src <- c("(Intercept)", attr(terms_x, "term.labels"))[attr(x, "assign") + 1]
  keep <- colnames(x) != "(Intercept)"
  x <- x[, keep, drop = FALSE]
  src <- src[keep]

  contrib <- predict(fit$finalModel$booster, x, predcontrib = TRUE)
  bias_col <- ncol(contrib)                     # last column is the baseline
  prob_check <- plogis(rowSums(contrib))
  feat <- contrib[, -bias_col, drop = FALSE]
  stopifnot(ncol(feat) == ncol(x))

  list(
    prob     = prob_check,
    baseline = contrib[, bias_col],
    long = tibble(
      row      = rep(seq_len(nrow(feat)), times = ncol(feat)),
      column   = rep(colnames(x), each = nrow(feat)),
      variable = rep(src, each = nrow(feat)),
      value    = as.vector(x),
      contribution = as.vector(feat)
    )
  )
}

# Plain-English theme for each source variable, for the slides.
theme_of <- function(v) {
  case_when(
    str_detect(v, regex("ext_source|ext_mean", ignore_case = TRUE)) ~ "Outside credit scores",
    str_detect(v, "^ltv") ~ "Loan vs. price of goods",
    str_detect(v, "credit_to_annuity|AMT_ANNUITY|AMT_CREDIT|AMT_GOODS_PRICE|^pti|credit_to_income") ~ "Loan size and payments",
    str_detect(v, "bureau|thin_file") ~ "Credit bureau history",
    str_detect(v, "^age_") ~ "Age",
    str_detect(v, "employ|tenure") ~ "Job stability",
    v == "NAME_EDUCATION_TYPE" ~ "Education",
    v == "CODE_GENDER" ~ "Gender",
    str_detect(v, "missing|no_inquiry") ~ "Missing information",
    str_detect(v, "INCOME") ~ "Income",
    str_detect(v, "HOUSING|_AVG$|_MODE$|_MEDI$|REGION|years_since_registration") ~ "Housing and location",
    str_detect(v, "FAMILY|CHILDREN|FAM_MEMBERS") ~ "Family",
    TRUE ~ "Other application details"
  )
}
