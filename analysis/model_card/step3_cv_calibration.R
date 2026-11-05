# Step 3 of the model card: full-scale five-fold cross-validation of the final
# XGBoost configuration on the development data, with calibration diagnostics.
#
# * Reproduces the modeling.qmd 80/20 split (seed 6493). Holdout rows are never
#   used here: not for CV, preprocessing, calibration fitting, or selection.
# * Primary OOF predictions use FOLD-SPECIFIC preprocessing: the
#   data_preparation.R parameters (income cap, missing-flag columns, PTI cutoffs,
#   medians, factor levels) are re-learned from each training fold's raw rows.
# * A comparison OOF set uses the original train_prepared.rds (parameters
#   learned on all 307,511 labeled rows) on the same folds, to measure leakage.
# * Calibration (Platt, isotonic) is cross-fitted: each fold's calibrated score
#   comes from a calibrator fitted on the other four folds' OOF predictions.
#
# Writes only to models/model_card/. Does not modify any existing file.
#
#   "C:/Program Files/R/R-4.5.2/bin/Rscript.exe" analysis/model_card/step3_cv_calibration.R

suppressPackageStartupMessages({
  library(tidyverse)
  library(caret)
  library(xgboost)
  library(pROC)
})

out_dir <- "models/model_card"
log_msg <- function(...) cat(format(Sys.time(), "%H:%M:%S"), "-", ..., "\n")
t_start <- Sys.time()

# Functions only: data_preparation.R runs its pipeline only when executed
# directly (sys.nframe() == 0), so sourcing it does not write anything.
source("data_preparation.R")

# -----------------------------------------------------------------------------
# 1. Data and the original development / holdout split
# -----------------------------------------------------------------------------
train_prepared <- readRDS("homecredit-eda/data/prepared/train_prepared.rds")
final_model    <- readRDS("models/final_home_credit_xgb.rds")  # read-only

# Exactly as in modeling.qmd, chunk "holdout-split".
set.seed(6493)
dev_index <- createDataPartition(factor(train_prepared$TARGET), p = 0.8,
                                 list = FALSE)[, 1]
development_data <- train_prepared[dev_index, ]
holdout_ids      <- train_prepared$SK_ID_CURR[-dev_index]

split_checks <- tibble(
  Check = c("Development rows = 246,009", "Holdout rows = 61,502",
            "Development defaults = 19,860 (modeling.html)",
            "Holdout defaults = 4,965 (modeling.html)",
            "No ID in both development and holdout"),
  Passed = c(nrow(development_data) == 246009, length(holdout_ids) == 61502,
             sum(development_data$TARGET) == 19860,
             sum(train_prepared$TARGET[-dev_index]) == 4965,
             length(intersect(development_data$SK_ID_CURR, holdout_ids)) == 0))
print(split_checks)
stopifnot(all(split_checks$Passed))

# -----------------------------------------------------------------------------
# 2. Five stratified folds within the development data
# -----------------------------------------------------------------------------
fold_seed <- 20261025
set.seed(fold_seed)
fold_test_index <- createFolds(factor(development_data$TARGET), k = 5,
                               list = TRUE, returnTrain = FALSE)
fold_of_row <- integer(nrow(development_data))
for (k in seq_along(fold_test_index)) fold_of_row[fold_test_index[[k]]] <- k
fold_assignments <- tibble(SK_ID_CURR = development_data$SK_ID_CURR,
                           TARGET = development_data$TARGET, fold = fold_of_row)
stopifnot(all(fold_of_row %in% 1:5))

# -----------------------------------------------------------------------------
# 3. Raw data for fold-specific preprocessing, and a pipeline reproduction check
# -----------------------------------------------------------------------------
log_msg("Loading raw data")
raw <- load_raw_data("homecredit-eda/data")
bureau_agg <- aggregate_bureau(raw$bureau)  # per-applicant only; nothing learned
raw_train <- raw$train
rm(raw); invisible(gc())

log_msg("Reproducing train_prepared.rds from raw data")
full_prep <- prepare_application(raw_train, bureau_agg)
pipeline_reproduces <- isTRUE(all.equal(as.data.frame(full_prep$data),
                                        as.data.frame(train_prepared),
                                        check.attributes = FALSE))
log_msg("Pipeline reproduces train_prepared.rds:", pipeline_reproduces)
global_params <- full_prep$params
rm(full_prep); invisible(gc())

# -----------------------------------------------------------------------------
# 4. Model: the original caret custom method stored in the saved final model
# -----------------------------------------------------------------------------
xgb_method  <- final_model$modelInfo
final_params <- data.frame(nrounds = 300, max_depth = 2, eta = 0.047, gamma = 4,
                           colsample_bytree = 0.95, min_child_weight = 10,
                           subsample = 0.86)
stopifnot(isTRUE(all.equal(final_params, final_model$bestTune, check.attributes = FALSE)))
rm(final_model); invisible(gc())

to_model_data <- function(df) {
  df |>
    mutate(TARGET = factor(if_else(TARGET == 1, "Default", "NoDefault"),
                           levels = c("Default", "NoDefault"))) |>
    select(-SK_ID_CURR)
}

fit_xgb <- function(model_data, seed) {
  set.seed(seed)
  train(TARGET ~ ., data = model_data,
        method    = xgb_method,
        trControl = trainControl(method = "none", classProbs = TRUE),
        tuneGrid  = final_params,
        nthread   = 4)
}

auc_of <- function(y, p) {
  as.numeric(auc(roc(y, p, levels = c(0, 1), direction = "<", quiet = TRUE)))
}

# -----------------------------------------------------------------------------
# 5. Cross-validation
# -----------------------------------------------------------------------------
oof <- vector("list", 5)
fold_info <- vector("list", 5)
prep_differences <- vector("list", 5)

for (k in 1:5) {
  eval_ids  <- development_data$SK_ID_CURR[fold_test_index[[k]]]
  train_ids <- development_data$SK_ID_CURR[-fold_test_index[[k]]]
  stopifnot(length(intersect(eval_ids, train_ids)) == 0,
            length(intersect(c(eval_ids, train_ids), holdout_ids)) == 0,
            length(eval_ids) + length(train_ids) == nrow(development_data))

  # (a) Primary: preprocessing learned from this training fold only.
  log_msg("Fold", k, "- fold-specific preprocessing")
  prep_tr <- prepare_application(filter(raw_train, SK_ID_CURR %in% train_ids), bureau_agg)
  prep_ev <- prepare_application(filter(raw_train, SK_ID_CURR %in% eval_ids), bureau_agg,
                                 params = prep_tr$params)
  stopifnot(identical(sort(prep_ev$data$SK_ID_CURR), sort(eval_ids)))

  p <- prep_tr$params
  prep_differences[[k]] <- tibble(
    fold = k,
    income_cap = p$income_cap, income_cap_global = global_params$income_cap,
    n_missing_flags = length(p$missing_flag_cols),
    flags_added   = paste(setdiff(p$missing_flag_cols, global_params$missing_flag_cols), collapse = "; "),
    flags_dropped = paste(setdiff(global_params$missing_flag_cols, p$missing_flag_cols), collapse = "; "),
    pti_breaks_max_abs_diff = if (length(p$pti_breaks) == length(global_params$pti_breaks))
      max(abs(p$pti_breaks - global_params$pti_breaks)[is.finite(p$pti_breaks)]) else NA_real_,
    n_features = length(p$feature_cols),
    features_identical_to_global = identical(p$feature_cols, global_params$feature_cols),
    factor_levels_identical_to_global = identical(map(p$category_levels, "levels"),
                                                  map(global_params$category_levels, "levels")))

  log_msg("Fold", k, "- fitting (fold-specific preprocessing)")
  t_fit <- system.time(fit_a <- fit_xgb(to_model_data(prep_tr$data), seed = 6493 + k))["elapsed"]
  prob_a <- predict(fit_a, newdata = to_model_data(prep_ev$data), type = "prob")$Default
  rm(fit_a, prep_tr); invisible(gc())

  # (b) Comparison: original globally prepared data, same rows.
  log_msg("Fold", k, "- fitting (original global preprocessing)")
  tr_glob <- filter(development_data, SK_ID_CURR %in% train_ids)
  ev_glob <- filter(development_data, SK_ID_CURR %in% eval_ids)
  fit_b <- fit_xgb(to_model_data(tr_glob), seed = 6493 + k)
  prob_b <- predict(fit_b, newdata = to_model_data(ev_glob), type = "prob")$Default
  rm(fit_b, tr_glob); invisible(gc())

  oof[[k]] <- tibble(SK_ID_CURR = prep_ev$data$SK_ID_CURR, TARGET = prep_ev$data$TARGET,
                     fold = k, prob_raw = prob_a) |>
    left_join(tibble(SK_ID_CURR = ev_glob$SK_ID_CURR, prob_raw_global_prep = prob_b),
              by = "SK_ID_CURR")
  fold_info[[k]] <- tibble(fold = k, train_rows = length(train_ids), eval_rows = length(eval_ids),
                           eval_defaults = sum(oof[[k]]$TARGET),
                           fit_seconds = unname(t_fit))
  log_msg("Fold", k, "- AUC fold-specific:", round(auc_of(oof[[k]]$TARGET, prob_a), 4),
          " global:", round(auc_of(oof[[k]]$TARGET, oof[[k]]$prob_raw_global_prep), 4))
  rm(prep_ev, ev_glob); invisible(gc())
}

oof <- bind_rows(oof) |> arrange(SK_ID_CURR)
fold_info <- bind_rows(fold_info)
prep_differences <- bind_rows(prep_differences)

# Labels must match the development split exactly.
check_labels <- inner_join(oof, fold_assignments, by = "SK_ID_CURR", suffix = c("", "_split"))
stopifnot(nrow(oof) == nrow(development_data), !anyDuplicated(oof$SK_ID_CURR),
          nrow(check_labels) == nrow(oof),
          all(check_labels$TARGET == check_labels$TARGET_split),
          all(check_labels$fold == check_labels$fold_split),
          !any(oof$SK_ID_CURR %in% holdout_ids), !anyNA(oof$prob_raw),
          !anyNA(oof$prob_raw_global_prep))

# -----------------------------------------------------------------------------
# 6. Cross-fitted calibration (development OOF only)
# -----------------------------------------------------------------------------
eps <- 1e-15
clip <- function(p) pmin(pmax(p, eps), 1 - eps)

fit_platt <- function(y, p) glm(y ~ qlogis(clip(p)), family = binomial())
apply_platt <- function(fit, p) {
  b <- coef(fit); plogis(b[1] + b[2] * qlogis(clip(p)))
}
fit_isotonic <- function(y, p) {
  o <- order(p); ir <- isoreg(p[o], y[o])
  # Step function on the sorted scores; clamp outside the fitted range.
  list(x = ir$x, y = ir$yf)
}
apply_isotonic <- function(fit, p) {
  f <- approxfun(fit$x, fit$y, method = "constant", rule = 2, f = 0, ties = "ordered")
  f(p)
}

oof$prob_platt_cf <- NA_real_
oof$prob_isotonic_cf <- NA_real_
for (k in 1:5) {
  fit_rows <- oof$fold != k
  pl <- fit_platt(oof$TARGET[fit_rows], oof$prob_raw[fit_rows])
  iso <- fit_isotonic(oof$TARGET[fit_rows], oof$prob_raw[fit_rows])
  oof$prob_platt_cf[!fit_rows]    <- apply_platt(pl, oof$prob_raw[!fit_rows])
  oof$prob_isotonic_cf[!fit_rows] <- apply_isotonic(iso, oof$prob_raw[!fit_rows])
}

# Final calibrators fitted on ALL development OOF predictions, saved for later
# application to a development-only refit scored on the untouched holdout.
platt_final    <- fit_platt(oof$TARGET, oof$prob_raw)
isotonic_final <- fit_isotonic(oof$TARGET, oof$prob_raw)

# -----------------------------------------------------------------------------
# 7. Metrics
# -----------------------------------------------------------------------------
brier   <- function(y, p) mean((p - y)^2)
logloss <- function(y, p) { p <- clip(p); -mean(y * log(p) + (1 - y) * log(1 - p)) }
cal_int_slope <- function(y, p) {
  lp <- qlogis(clip(p))
  slope_fit <- glm(y ~ lp, family = binomial())
  citl_fit  <- glm(y ~ 1, offset = lp, family = binomial())
  ci_s <- confint.default(slope_fit)["lp", ]
  ci_i <- confint.default(citl_fit)[1, ]
  c(cal_intercept = unname(coef(citl_fit)[1]), cal_intercept_lo = ci_i[[1]], cal_intercept_hi = ci_i[[2]],
    cal_slope = unname(coef(slope_fit)["lp"]), cal_slope_lo = ci_s[[1]], cal_slope_hi = ci_s[[2]])
}
ece <- function(y, p, bins = 20) {
  b <- cut(p, unique(quantile(p, seq(0, 1, length.out = bins + 1))), include.lowest = TRUE)
  d <- tibble(y, p, b) |> group_by(b) |> summarise(n = n(), gap = abs(mean(p) - mean(y)))
  sum(d$n * d$gap) / length(y)
}
score_set <- function(y, p) {
  c(auc = auc_of(y, p), brier = brier(y, p), log_loss = logloss(y, p),
    mean_pred = mean(p), observed_rate = mean(y), ece_20_quantile_bins = ece(y, p),
    cal_int_slope(y, p))
}

fold_metrics <- oof |>
  group_by(fold) |>
  summarise(auc = auc_of(TARGET, prob_raw),
            auc_global_prep = auc_of(TARGET, prob_raw_global_prep),
            brier = brier(TARGET, prob_raw), log_loss = logloss(TARGET, prob_raw),
            prevalence = mean(TARGET), mean_pred = mean(prob_raw), .groups = "drop") |>
  left_join(fold_info, by = "fold")

summary_metrics <- tibble(
  Metric = c("Mean 5-fold AUC (fold-specific prep)", "SD 5-fold AUC (fold-specific prep)",
             "Pooled OOF AUC (fold-specific prep)",
             "Mean 5-fold AUC (original global prep)", "SD 5-fold AUC (original global prep)",
             "Pooled OOF AUC (original global prep)",
             "Pooled AUC difference (global - fold-specific)",
             "Development prevalence (TARGET = 1)", "OOF rows", "Holdout rows used"),
  Value = c(mean(fold_metrics$auc), sd(fold_metrics$auc), auc_of(oof$TARGET, oof$prob_raw),
            mean(fold_metrics$auc_global_prep), sd(fold_metrics$auc_global_prep),
            auc_of(oof$TARGET, oof$prob_raw_global_prep),
            auc_of(oof$TARGET, oof$prob_raw_global_prep) - auc_of(oof$TARGET, oof$prob_raw),
            mean(oof$TARGET), nrow(oof), 0))

score_cols <- c(raw = "prob_raw", platt_cross_fitted = "prob_platt_cf",
                isotonic_cross_fitted = "prob_isotonic_cf",
                raw_global_prep = "prob_raw_global_prep")
calibration_comparison <- imap(score_cols, function(col, name) {
  as_tibble_row(as.list(score_set(oof$TARGET, oof[[col]]))) |> mutate(score = name, .before = 1)
}) |> list_rbind()

# Reliability bins: 20 equal-count bins of the raw score, Wilson 95% CIs.
wilson <- function(x, n, z = 1.96) {
  p <- x / n; d <- 1 + z^2 / n
  c <- (p + z^2 / (2 * n)) / d; h <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / d
  cbind(lo = c - h, hi = c + h)
}
reliability <- function(p, y, label, bins = 20) {
  b <- cut(p, unique(quantile(p, seq(0, 1, length.out = bins + 1))),
           include.lowest = TRUE, labels = FALSE)
  tibble(p, y, bin = b) |>
    group_by(bin) |>
    summarise(n = n(), events = sum(y), mean_pred = mean(p), observed = mean(y),
              p_min = min(p), p_max = max(p), .groups = "drop") |>
    mutate(ci = wilson(events, n), observed_lo = ci[, "lo"], observed_hi = ci[, "hi"],
           score = label) |>
    select(-ci)
}
calibration_bins <- bind_rows(reliability(oof$prob_raw, oof$TARGET, "raw"),
                              reliability(oof$prob_platt_cf, oof$TARGET, "platt_cross_fitted"),
                              reliability(oof$prob_isotonic_cf, oof$TARGET, "isotonic_cross_fitted"))

# Risk bands: terciles of the raw score, plus fixed bands spanning the Step 2
# break-even range (0.036 to 0.549).
band_table <- function(score_col, label) {
  p <- oof[[score_col]]
  terc <- quantile(oof$prob_raw, c(1/3, 2/3))
  bind_rows(
    tibble(band = cut(oof$prob_raw, c(-Inf, terc, Inf), labels = c("Low (bottom third)", "Medium (middle third)", "High (top third)")),
           p, y = oof$TARGET, scheme = "Terciles of raw score"),
    tibble(band = cut(oof$prob_raw, c(-Inf, 0.05, 0.10, 0.20, 0.30, 0.40, Inf),
                      labels = c("< 0.05", "0.05-0.10", "0.10-0.20", "0.20-0.30", "0.30-0.40", ">= 0.40"),
                      right = FALSE),
           p, y = oof$TARGET, scheme = "Fixed raw-score bands")) |>
    group_by(scheme, band) |>
    summarise(n = n(), events = sum(y), mean_pred = mean(p), observed = mean(y), .groups = "drop") |>
    mutate(ci = wilson(events, n), observed_lo = ci[, "lo"], observed_hi = ci[, "hi"],
           pred_minus_observed = mean_pred - observed, score = label) |>
    select(-ci)
}
risk_bands <- bind_rows(band_table("prob_raw", "raw"),
                        band_table("prob_platt_cf", "platt_cross_fitted"),
                        band_table("prob_isotonic_cf", "isotonic_cross_fitted"))

# -----------------------------------------------------------------------------
# 8. Figures
# -----------------------------------------------------------------------------
roc_obj <- roc(oof$TARGET, oof$prob_raw, levels = c(0, 1), direction = "<", quiet = TRUE)
roc_df <- bind_rows(
  tibble(fpr = 1 - roc_obj$specificities, tpr = roc_obj$sensitivities, curve = "Pooled OOF"),
  imap(split(oof, oof$fold), function(d, k) {
    r <- roc(d$TARGET, d$prob_raw, levels = c(0, 1), direction = "<", quiet = TRUE)
    tibble(fpr = 1 - r$specificities, tpr = r$sensitivities, curve = paste("Fold", k))
  }) |> list_rbind())
pooled_auc <- auc_of(oof$TARGET, oof$prob_raw)
g_roc <- ggplot(roc_df, aes(fpr, tpr, group = curve)) +
  geom_abline(linetype = "dashed", colour = "grey60") +
  geom_line(data = filter(roc_df, curve != "Pooled OOF"), colour = "grey70", linewidth = 0.4) +
  geom_line(data = filter(roc_df, curve == "Pooled OOF"), colour = "#2c5f8a", linewidth = 0.9) +
  coord_equal() +
  labs(x = "False positive rate (1 - specificity)", y = "True positive rate (sensitivity)",
       title = "Five-fold OOF ROC curve, development data",
       subtitle = sprintf("Pooled OOF AUC = %.4f; grey lines are individual folds", pooled_auc)) +
  theme_bw(base_size = 11)
ggsave(file.path(out_dir, "step3_roc_curve.png"), g_roc, width = 6, height = 6, dpi = 150)

g_rel_raw <- calibration_bins |> filter(score == "raw") |>
  ggplot(aes(mean_pred, observed)) +
  geom_abline(linetype = "dashed", colour = "grey50") +
  geom_errorbar(aes(ymin = observed_lo, ymax = observed_hi), width = 0, colour = "grey50") +
  geom_point(colour = "#2c5f8a", size = 2) +
  geom_line(colour = "#2c5f8a") +
  coord_equal(xlim = c(0, 0.45), ylim = c(0, 0.45)) +
  labs(x = "Mean predicted probability (bin)", y = "Observed TARGET = 1 rate (bin)",
       title = "Reliability of raw OOF probabilities",
       subtitle = "20 equal-count bins; bars are Wilson 95% intervals") +
  theme_bw(base_size = 11)
ggsave(file.path(out_dir, "step3_reliability_raw.png"), g_rel_raw, width = 6, height = 6, dpi = 150)

g_rel_all <- calibration_bins |>
  mutate(score = factor(score, c("raw", "platt_cross_fitted", "isotonic_cross_fitted"),
                        c("Raw", "Platt (cross-fitted)", "Isotonic (cross-fitted)"))) |>
  ggplot(aes(mean_pred, observed)) +
  geom_abline(linetype = "dashed", colour = "grey50") +
  geom_errorbar(aes(ymin = observed_lo, ymax = observed_hi), width = 0, colour = "grey50") +
  geom_point(colour = "#2c5f8a", size = 1.6) + geom_line(colour = "#2c5f8a") +
  facet_wrap(~ score) +
  coord_equal(xlim = c(0, 0.45), ylim = c(0, 0.45)) +
  labs(x = "Mean predicted probability (bin)", y = "Observed TARGET = 1 rate (bin)",
       title = "Reliability: raw vs cross-fitted calibration") +
  theme_bw(base_size = 11)
ggsave(file.path(out_dir, "step3_reliability_methods.png"), g_rel_all, width = 10, height = 4, dpi = 150)

g_hist <- ggplot(oof, aes(prob_raw, fill = factor(TARGET))) +
  geom_histogram(bins = 60, position = "identity", alpha = 0.55) +
  scale_fill_manual(values = c(`0` = "grey55", `1` = "#c0504d"), labels = c("TARGET = 0", "TARGET = 1"), name = NULL) +
  labs(x = "Raw OOF predicted probability", y = "Applicants", title = "Distribution of raw OOF probabilities") +
  theme_bw(base_size = 11)
ggsave(file.path(out_dir, "step3_score_distribution.png"), g_hist, width = 7, height = 4, dpi = 150)

# -----------------------------------------------------------------------------
# 9. Save
# -----------------------------------------------------------------------------
saveRDS(oof, file.path(out_dir, "step3_oof_predictions.rds"))
write_csv(fold_metrics, file.path(out_dir, "step3_fold_metrics.csv"))
write_csv(summary_metrics, file.path(out_dir, "step3_summary_metrics.csv"))
write_csv(calibration_comparison, file.path(out_dir, "step3_calibration_comparison.csv"))
write_csv(calibration_bins, file.path(out_dir, "step3_calibration_bins.csv"))
write_csv(risk_bands, file.path(out_dir, "step3_risk_band_calibration.csv"))
write_csv(prep_differences, file.path(out_dir, "step3_fold_preprocessing_differences.csv"))
write_csv(split_checks, file.path(out_dir, "step3_split_checks.csv"))

saveRDS(list(
  platt = list(coefficients = coef(platt_final),
               formula = "p_cal = plogis(a + b * qlogis(p_raw))",
               apply = apply_platt),
  isotonic = list(x = isotonic_final$x, y = isotonic_final$y,
                  apply = apply_isotonic,
                  note = "Step function on raw score; constant outside fitted range"),
  fitted_on = "All 246,009 development OOF predictions (fold-specific preprocessing); holdout never used",
  clip_eps = eps), file.path(out_dir, "step3_calibrators.rds"))

metadata <- list(
  created = format(Sys.time(), tz = "UTC", usetz = TRUE),
  runtime_minutes = as.numeric(difftime(Sys.time(), t_start, units = "mins")),
  split = list(seed = 6493, method = "caret::createDataPartition(factor(TARGET), p = 0.8)",
               development_rows = nrow(development_data), holdout_rows = length(holdout_ids)),
  folds = list(k = 5, seed = fold_seed, method = "caret::createFolds(factor(TARGET), k = 5)"),
  model = list(method = "caret custom xgbTree (modelInfo copied from models/final_home_credit_xgb.rds)",
               hyperparameters = final_params, objective = "binary:logistic",
               eval_metric = "logloss", nthread = 4, fit_seeds = 6493 + 1:5,
               imbalance_adjustment = "none"),
  preprocessing = list(primary = "data_preparation.R parameters re-learned on each training fold",
                       comparison = "original train_prepared.rds (parameters learned on all 307,511 rows)",
                       pipeline_reproduces_train_prepared = pipeline_reproduces,
                       not_refit = "Fixed bands (LTV, age, tenure, bureau depth, fields missing) were read from EDA plots of the full training data and cannot be re-learned"),
  calibration = list(cross_fitting = "calibrator for fold k fitted on OOF predictions of the other 4 folds",
                     final_calibrators = "fitted on all development OOF predictions; see step3_calibrators.rds"),
  versions = list(R = R.version.string, xgboost = as.character(packageVersion("xgboost")),
                  caret = as.character(packageVersion("caret")),
                  pROC = as.character(packageVersion("pROC"))))
saveRDS(metadata, file.path(out_dir, "step3_metadata.rds"))
writeLines(c(paste("Run at:", metadata$created), capture.output(sessionInfo())),
           file.path(out_dir, "step3_session_info.txt"))

# -----------------------------------------------------------------------------
# 10. Console report
# -----------------------------------------------------------------------------
options(width = 160, pillar.sigfig = 5)
cat("\n== Pipeline reproduces train_prepared.rds:", pipeline_reproduces, "\n")
cat("\n== Fold metrics ==\n"); print(fold_metrics, width = Inf)
cat("\n== Summary ==\n"); print(as.data.frame(summary_metrics), digits = 6)
cat("\n== Calibration comparison ==\n"); print(as.data.frame(calibration_comparison), digits = 5)
cat("\n== Risk bands ==\n"); print(as.data.frame(risk_bands), digits = 4)
cat("\n== Raw reliability bins ==\n"); print(as.data.frame(filter(calibration_bins, score == "raw")), digits = 4)
cat("\n== Fold preprocessing vs global ==\n"); print(as.data.frame(prep_differences))
cat("\n== Final Platt coefficients ==\n"); print(coef(platt_final))
cat("\nRuntime (min):", round(metadata$runtime_minutes, 1), "\n")
