# Step 5 of the model card: one-time evaluation on the untouched 61,502-row
# holdout, using a development-only model, the frozen Step 3 Platt calibrator
# and the frozen Step 4 threshold (0.25). Nothing here is tuned on the holdout.
#
# * Preprocessing (data_preparation.R, sourced unmodified) is learned on the
#   246,009 development rows only and applied unchanged to the holdout.
# * Model: original caret custom xgbTree method and final hyperparameters,
#   fit once on development data with seed 6493.
# * TARGET = 1 means payment difficulty, not a confirmed write-off. Money
#   figures are hypothetical Step 2 scenario proxies, not observed profits.
#
# Writes only to models/model_card/.
#   "C:/Program Files/R/R-4.5.2/bin/Rscript.exe" analysis/model_card/step5_holdout_evaluation.R

suppressPackageStartupMessages({
  library(tidyverse); library(caret); library(xgboost); library(pROC)
})
out_dir   <- "models/model_card"
THRESHOLD <- 0.25          # frozen in Step 4
principal <- 8437          # $ illustration only (TransUnion Q2 2026)
log_msg <- function(...) cat(format(Sys.time(), "%H:%M:%S"), "-", ..., "\n")
source("data_preparation.R")  # functions only

# -----------------------------------------------------------------------------
# 1. Split and isolation checks
# -----------------------------------------------------------------------------
train_prepared <- readRDS("homecredit-eda/data/prepared/train_prepared.rds")
set.seed(6493)
dev_index <- createDataPartition(factor(train_prepared$TARGET), p = 0.8, list = FALSE)[, 1]
dev_ids  <- train_prepared$SK_ID_CURR[dev_index]
hold_ids <- train_prepared$SK_ID_CURR[-dev_index]

oof <- readRDS(file.path(out_dir, "step3_oof_predictions.rds"))
calibrators <- readRDS(file.path(out_dir, "step3_calibrators.rds"))
step3_meta  <- readRDS(file.path(out_dir, "step3_metadata.rds"))

isolation_checks <- tibble(
  Check = c("Development rows = 246,009", "Development TARGET = 1 = 19,860",
            "Holdout rows = 61,502", "Holdout TARGET = 1 = 4,965",
            "No ID in both development and holdout",
            "Step 3 OOF IDs == development IDs (no holdout ID in CV)",
            "Platt calibrator fitted on development OOF only (n = 246,009)",
            "Step 4 threshold source = development OOF only (no holdout ID in its input)"),
  Passed = c(length(dev_ids) == 246009, sum(train_prepared$TARGET[dev_index]) == 19860,
             length(hold_ids) == 61502, sum(train_prepared$TARGET[-dev_index]) == 4965,
             length(intersect(dev_ids, hold_ids)) == 0,
             setequal(oof$SK_ID_CURR, dev_ids) && !any(oof$SK_ID_CURR %in% hold_ids),
             grepl("development OOF", calibrators$fitted_on) && step3_meta$split$development_rows == 246009,
             !any(oof$SK_ID_CURR %in% hold_ids)))
print(isolation_checks)
stopifnot(all(isolation_checks$Passed))

# -----------------------------------------------------------------------------
# 2. Development-only preprocessing and model
# -----------------------------------------------------------------------------
log_msg("Loading raw data")
raw <- load_raw_data("homecredit-eda/data")
bureau_agg <- aggregate_bureau(raw$bureau)
raw_dev  <- filter(raw$train, SK_ID_CURR %in% dev_ids)
raw_hold <- filter(raw$train, SK_ID_CURR %in% hold_ids)
demographics <- raw$train |> select(SK_ID_CURR, CODE_GENDER, NAME_EDUCATION_TYPE)  # raw values
rm(raw); invisible(gc())

prep_dev  <- prepare_application(raw_dev, bureau_agg)
prep_hold <- prepare_application(raw_hold, bureau_agg, params = prep_dev$params)
dev_params <- prep_dev$params

factor_levels <- function(df) map(select(df, where(is.factor)), levels)
alignment_checks <- tibble(
  Check = c("Holdout columns identical to development (names and order)",
            "Holdout column types identical", "Holdout factor levels identical",
            "No missing values (development, holdout)",
            "Holdout prepared rows = 61,502, one per SK_ID_CURR",
            "Holdout TARGET unchanged by preparation"),
  Passed = c(identical(names(prep_dev$data), names(prep_hold$data)),
             identical(map_chr(prep_dev$data, ~ class(.x)[1]), map_chr(prep_hold$data, ~ class(.x)[1])),
             identical(factor_levels(prep_dev$data), factor_levels(prep_hold$data)),
             !anyNA(prep_dev$data) && !anyNA(prep_hold$data),
             nrow(prep_hold$data) == 61502 && !anyDuplicated(prep_hold$data$SK_ID_CURR),
             sum(prep_hold$data$TARGET) == 4965))
print(alignment_checks)
stopifnot(all(alignment_checks$Passed))

global_params <- readRDS("homecredit-eda/data/prepared/prep_params.rds")
param_comparison <- tibble(
  item = c("income_cap", "missing_flag_cols (set)", "missing_flag_cols (order)",
           "feature_cols (set)", "feature_cols (order)", "category levels"),
  identical_to_global = c(dev_params$income_cap == global_params$income_cap,
                          setequal(dev_params$missing_flag_cols, global_params$missing_flag_cols),
                          identical(dev_params$missing_flag_cols, global_params$missing_flag_cols),
                          setequal(dev_params$feature_cols, global_params$feature_cols),
                          identical(dev_params$feature_cols, global_params$feature_cols),
                          identical(map(dev_params$category_levels, "levels"),
                                    map(global_params$category_levels, "levels"))),
  dev_value = c(format(dev_params$income_cap), length(dev_params$missing_flag_cols), "", length(dev_params$feature_cols), "", ""),
  global_value = c(format(global_params$income_cap), length(global_params$missing_flag_cols), "", length(global_params$feature_cols), "", ""))

final_model <- readRDS("models/final_home_credit_xgb.rds")   # read-only: method + params
xgb_method <- final_model$modelInfo
final_params <- final_model$bestTune
rm(final_model); invisible(gc())

to_model_data <- function(df) {
  df |> mutate(TARGET = factor(if_else(TARGET == 1, "Default", "NoDefault"),
                               levels = c("Default", "NoDefault"))) |>
    select(-SK_ID_CURR)
}
fit_xgb <- function(model_data) {
  set.seed(6493)
  train(TARGET ~ ., data = model_data, method = xgb_method,
        trControl = trainControl(method = "none", classProbs = TRUE),
        tuneGrid = final_params, nthread = 4)
}

log_msg("Fitting development-only model (dev-only preprocessing)")
t_fit <- system.time(dev_model <- fit_xgb(to_model_data(prep_dev$data)))["elapsed"]
saveRDS(dev_model, file.path(out_dir, "step5_dev_only_xgb.rds"))
saveRDS(dev_params, file.path(out_dir, "step5_dev_only_prep_params.rds"))

hold_x <- to_model_data(prep_hold$data)
prob_raw <- predict(dev_model, newdata = hold_x, type = "prob")$Default

# Reproduction check only (not used for any result): the original workflow
# (global preprocessing, seed 6493) should reproduce modeling.qmd's 0.7556.
log_msg("Reproduction check: original global preprocessing")
repro_model <- fit_xgb(to_model_data(train_prepared[dev_index, ]))
repro_prob  <- predict(repro_model, newdata = to_model_data(train_prepared[-dev_index, ]), type = "prob")$Default
repro_auc   <- as.numeric(auc(train_prepared$TARGET[-dev_index], repro_prob, levels = c(0, 1), direction = "<", quiet = TRUE))
rm(repro_model); invisible(gc())

# -----------------------------------------------------------------------------
# 3. Frozen Platt calibration
# -----------------------------------------------------------------------------
eps <- calibrators$clip_eps
clip <- function(p) pmin(pmax(p, eps), 1 - eps)
a <- unname(calibrators$platt$coefficients[1]); b <- unname(calibrators$platt$coefficients[2])
prob_platt <- plogis(a + b * qlogis(clip(prob_raw)))
# Cross-check against the function saved with the calibrator in Step 3
# (it reads coef(fit), which works on any object with $coefficients).
stopifnot(all(prob_platt >= 0 & prob_platt <= 1),
          isTRUE(all.equal(prob_platt, unname(calibrators$platt$apply(list(coefficients = c(a, b)), prob_raw)))))

holdout <- tibble(SK_ID_CURR = prep_hold$data$SK_ID_CURR, TARGET = prep_hold$data$TARGET,
                  prob_raw = prob_raw, prob_platt = prob_platt) |>
  mutate(decision = if_else(prob_platt < THRESHOLD, "Approve", "Decline/refer")) |>
  left_join(demographics, by = "SK_ID_CURR") |>
  arrange(SK_ID_CURR)
stopifnot(nrow(holdout) == 61502, !anyNA(holdout$CODE_GENDER), !anyNA(holdout$NAME_EDUCATION_TYPE))
saveRDS(holdout, file.path(out_dir, "step5_holdout_predictions.rds"))

# -----------------------------------------------------------------------------
# 4. Metrics
# -----------------------------------------------------------------------------
y <- holdout$TARGET; n <- length(y)
wilson <- function(x, n, z = 1.96) {
  if (n == 0) return(c(NA_real_, NA_real_))
  p <- x / n; d <- 1 + z^2 / n
  c0 <- (p + z^2 / (2 * n)) / d; h <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / d
  c(c0 - h, c0 + h)
}
brier <- function(y, p) mean((p - y)^2)
logloss <- function(y, p) { p <- clip(p); -mean(y * log(p) + (1 - y) * log(1 - p)) }
cal_int_slope <- function(y, p) {
  lp <- qlogis(clip(p))
  s <- glm(y ~ lp, family = binomial()); i <- glm(y ~ 1, offset = lp, family = binomial())
  ci_s <- confint.default(s)["lp", ]; ci_i <- confint.default(i)[1, ]
  c(cal_intercept = unname(coef(i)[1]), cal_intercept_lo = ci_i[[1]], cal_intercept_hi = ci_i[[2]],
    cal_slope = unname(coef(s)["lp"]), cal_slope_lo = ci_s[[1]], cal_slope_hi = ci_s[[2]])
}
ece <- function(y, p, bins = 20) {
  bb <- cut(p, unique(quantile(p, seq(0, 1, length.out = bins + 1))), include.lowest = TRUE)
  d <- tibble(y, p, bb) |> group_by(bb) |> summarise(n = n(), gap = abs(mean(p) - mean(y)))
  sum(d$n * d$gap) / length(y)
}
auc_ci <- function(y, p) {
  r <- roc(y, p, levels = c(0, 1), direction = "<", quiet = TRUE)
  ci <- ci.auc(r, method = "delong"); c(auc = ci[2], auc_lo = ci[1], auc_hi = ci[3])
}
prob_metrics <- function(y, p, set, score) {
  as_tibble_row(c(auc_ci(y, p), brier = brier(y, p), log_loss = logloss(y, p),
                  mean_pred = mean(p), observed_rate = mean(y), ece_20 = ece(y, p),
                  cal_int_slope(y, p))) |>
    mutate(set = set, score = score, n = length(y), .before = 1)
}
probability_metrics <- bind_rows(
  prob_metrics(y, holdout$prob_raw, "Holdout", "Raw"),
  prob_metrics(y, holdout$prob_platt, "Holdout", "Platt (frozen)"),
  prob_metrics(oof$TARGET, oof$prob_raw, "Development OOF", "Raw"),
  prob_metrics(oof$TARGET, oof$prob_platt_cf, "Development OOF", "Platt (cross-fitted)"))

classification <- function(y, p, t, set) {
  approve <- p < t
  tn <- sum(approve & y == 0); fn <- sum(approve & y == 1)
  tp <- sum(!approve & y == 1); fp <- sum(!approve & y == 0)
  nn <- length(y)
  w <- function(x, m) wilson(x, m)
  tibble(set = set, threshold = t, applicants = nn, approved = tn + fn, declined = tp + fp,
         TP_declined_target1 = tp, FP_declined_target0 = fp, TN_approved_target0 = tn, FN_approved_target1 = fn,
         approval_rate = (tn + fn) / nn, approval_lo = w(tn + fn, nn)[1], approval_hi = w(tn + fn, nn)[2],
         decline_rate = (tp + fp) / nn,
         precision = tp / (tp + fp), precision_lo = w(tp, tp + fp)[1], precision_hi = w(tp, tp + fp)[2],
         recall = tp / (tp + fn), recall_lo = w(tp, tp + fn)[1], recall_hi = w(tp, tp + fn)[2],
         specificity = tn / (tn + fp), specificity_lo = w(tn, tn + fp)[1], specificity_hi = w(tn, tn + fp)[2],
         fpr = fp / (tn + fp), fpr_lo = w(fp, tn + fp)[1], fpr_hi = w(fp, tn + fp)[2],
         target_rate_approved = fn / (tn + fn), target_rate_approved_lo = w(fn, tn + fn)[1], target_rate_approved_hi = w(fn, tn + fn)[2],
         target_rate_declined = tp / (tp + fp), target_rate_declined_lo = w(tp, tp + fp)[1], target_rate_declined_hi = w(tp, tp + fp)[2])
}
threshold_results <- bind_rows(classification(y, holdout$prob_platt, THRESHOLD, "Holdout"),
                               classification(oof$TARGET, oof$prob_platt_cf, THRESHOLD, "Development OOF"))

reliability <- function(p, y, label, bins = 20) {
  bb <- cut(p, unique(quantile(p, seq(0, 1, length.out = bins + 1))), include.lowest = TRUE, labels = FALSE)
  tibble(p, y, bin = bb) |> group_by(bin) |>
    summarise(n = n(), events = sum(y), mean_pred = mean(p), observed = mean(y), .groups = "drop") |>
    rowwise() |> mutate(observed_lo = wilson(events, n)[1], observed_hi = wilson(events, n)[2]) |> ungroup() |>
    mutate(score = label)
}
reliability_bins <- bind_rows(reliability(holdout$prob_raw, y, "Raw"),
                              reliability(holdout$prob_platt, y, "Platt (frozen)"))
risk_bands <- holdout |>
  mutate(band = cut(prob_platt, c(-Inf, 0.05, 0.10, 0.20, 0.25, 0.30, 0.40, Inf), right = FALSE,
                    labels = c("< 0.05", "0.05-0.10", "0.10-0.20", "0.20-0.25", "0.25-0.30", "0.30-0.40", ">= 0.40"))) |>
  group_by(band) |>
  summarise(n = n(), events = sum(TARGET), mean_platt = mean(prob_platt), mean_raw = mean(prob_raw),
            observed = mean(TARGET), .groups = "drop") |>
  rowwise() |> mutate(observed_lo = wilson(events, n)[1], observed_hi = wilson(events, n)[2]) |> ungroup()

# -----------------------------------------------------------------------------
# 5. Financial scenarios (identical construction to Step 4) + 36-month base
# -----------------------------------------------------------------------------
amortization <- function(apr, n) {
  r <- apr / 12; pmt <- r / (1 - (1 + r)^-n)
  bal <- numeric(n + 1); bal[1] <- 1
  for (k in 1:n) bal[k + 1] <- bal[k] * (1 + r) - pmt
  list(balance = bal, principal_years = sum(bal[1:n]) / 12)
}
make_scen <- function(name, m, k, lgd, c, term) {
  am <- amortization(0.40, term)
  G <- m * am$principal_years; L <- c * am$balance[k + 1] * lgd
  tibble(scenario = name, term_months = term, G = G, L = L, p_star = G / (G + L))
}
scenarios <- bind_rows(
  make_scen("Conservative", 0.0473 + 0.0141 - 0.0307, 0, 0.96, 1.00, 24),
  make_scen("Base (24-month)", 0.158 * (1 - 0.422), 3, (0.45 + 0.96) / 2, 0.50, 24),
  make_scen("Optimistic", 0.158 * (1 - 0.394), 6, 0.45, 0.25, 24),
  make_scen("Base, 36-month term", 0.158 * (1 - 0.422), 3, (0.45 + 0.96) / 2, 0.50, 36))
stopifnot(isTRUE(all.equal(round(scenarios$p_star[1:3], 4), c(0.0361, 0.2493, 0.5492))))

financials <- function(y, p, t, scen) {
  approve <- p < t
  tn <- sum(approve & y == 0); fn <- sum(approve & y == 1)
  tp <- sum(!approve & y == 1); fp <- sum(!approve & y == 0)
  scen |> mutate(threshold = t, applicants = length(y), approved = tn + fn,
                 profit_total = tn * G - fn * L,
                 approve_all_total = sum(y == 0) * G - sum(y == 1) * L,
                 avoided_proxy_losses = tp * L,
                 foregone_margin = fp * G,
                 improvement_total = profit_total - approve_all_total,
                 profit_per_applicant = profit_total / applicants,
                 profit_per_approved = profit_total / approved,
                 approve_all_per_applicant = approve_all_total / applicants,
                 improvement_per_applicant = improvement_total / applicants)
}
to_usd <- function(df) df |> mutate(across(c(profit_total, approve_all_total, avoided_proxy_losses, foregone_margin,
                                             improvement_total, profit_per_applicant, profit_per_approved,
                                             approve_all_per_applicant, improvement_per_applicant),
                                           ~ .x * principal, .names = "{.col}_usd"))
financial_results <- bind_rows(
  financials(y, holdout$prob_platt, THRESHOLD, scenarios) |> mutate(set = "Holdout", .before = 1),
  financials(oof$TARGET, oof$prob_platt_cf, THRESHOLD, scenarios) |> mutate(set = "Development OOF", .before = 1)) |>
  to_usd()
# Descriptive only: 36-month scenario evaluated at its own p* (NOT a threshold change).
financial_36_at_own_pstar <- financials(y, holdout$prob_platt, round(scenarios$p_star[4], 4), scenarios[4, ]) |>
  mutate(set = "Holdout (descriptive)", .before = 1) |> to_usd()

# Bootstrap (B = 1,000) for holdout metrics at the frozen threshold.
B <- 1000; set.seed(55)
approve <- holdout$prob_platt < THRESHOLD
boot <- map_dfr(1:B, function(i) {
  idx <- sample.int(n, n, replace = TRUE)
  yy <- y[idx]; aa <- approve[idx]
  tn <- sum(aa & yy == 0); fn <- sum(aa & yy == 1); tp <- sum(!aa & yy == 1); fp <- sum(!aa & yy == 0)
  out <- tibble(b = i, approval_rate = (tn + fn) / n, precision = tp / (tp + fp), recall = tp / (tp + fn))
  for (s in seq_len(nrow(scenarios))) {
    G <- scenarios$G[s]; L <- scenarios$L[s]
    out[[paste0("improvement_per_applicant_usd__", scenarios$scenario[s])]] <-
      ((tp * L - fp * G) / n) * principal
  }
  out
})
bootstrap_ci <- boot |> select(-b) |>
  pivot_longer(everything()) |>
  group_by(metric = name) |>
  summarise(lo95 = quantile(value, 0.025), median = median(value), hi95 = quantile(value, 0.975),
            share_positive = mean(value > 0), .groups = "drop")
roc_test <- roc.test(roc(y, holdout$prob_raw, levels = c(0, 1), direction = "<", quiet = TRUE),
                     roc(y, repro_prob, levels = c(0, 1), direction = "<", quiet = TRUE), method = "delong", paired = TRUE)

# -----------------------------------------------------------------------------
# 6. Initial fairness evaluation at the frozen threshold
# -----------------------------------------------------------------------------
group_metrics <- function(df, attr) {
  df |>
    group_by(group = .data[[attr]]) |>
    summarise(n = n(), events = sum(TARGET),
              approved = sum(prob_platt < THRESHOLD), declined = sum(prob_platt >= THRESHOLD),
              tp = sum(prob_platt >= THRESHOLD & TARGET == 1), fp = sum(prob_platt >= THRESHOLD & TARGET == 0),
              non_events = sum(TARGET == 0),
              mean_platt = mean(prob_platt), .groups = "drop") |>
    mutate(attribute = attr, .before = 1,
           share_of_holdout = n / sum(n),
           approval_rate = approved / n, decline_rate = declined / n,
           observed_rate = events / n,
           recall = if_else(events > 0, tp / events, NA_real_),
           fpr = if_else(non_events > 0, fp / non_events, NA_real_),
           precision = if_else(declined > 0, tp / declined, NA_real_),
           calibration_gap = mean_platt - observed_rate,
           small_sample_flag = n < 1000 | events < 100) |>
    rowwise() |>
    mutate(approval_lo = wilson(approved, n)[1], approval_hi = wilson(approved, n)[2],
           observed_lo = wilson(events, n)[1], observed_hi = wilson(events, n)[2],
           recall_lo = wilson(tp, events)[1], recall_hi = wilson(tp, events)[2],
           fpr_lo = wilson(fp, non_events)[1], fpr_hi = wilson(fp, non_events)[2]) |>
    ungroup()
}
fairness <- bind_rows(group_metrics(holdout, "CODE_GENDER"),
                      group_metrics(holdout, "NAME_EDUCATION_TYPE"))
# Differences vs the largest group in each attribute (normal-approximation CI).
fairness <- fairness |>
  group_by(attribute) |>
  mutate(reference_group = group[which.max(n)],
         ref_n = n[which.max(n)], ref_appr = approval_rate[which.max(n)],
         approval_diff_vs_ref = approval_rate - ref_appr,
         approval_diff_lo = approval_diff_vs_ref - 1.96 * sqrt(approval_rate * (1 - approval_rate) / n + ref_appr * (1 - ref_appr) / ref_n),
         approval_diff_hi = approval_diff_vs_ref + 1.96 * sqrt(approval_rate * (1 - approval_rate) / n + ref_appr * (1 - ref_appr) / ref_n),
         approval_ratio_vs_ref = approval_rate / ref_appr,
         decline_ratio_vs_ref = decline_rate / (1 - ref_appr),
         fpr_diff_vs_ref = fpr - fpr[which.max(n)],
         recall_diff_vs_ref = recall - recall[which.max(n)]) |>
  ungroup() |> select(-ref_n, -ref_appr)

# Model-use facts for the compliance note.
dev_terms <- attr(terms(dev_model), "term.labels")
protected_in_model <- tibble(
  attribute = c("CODE_GENDER", "NAME_EDUCATION_TYPE", "age_years", "age_band"),
  used_as_predictor = attribute %in% dev_terms)
imp <- xgb.importance(model = dev_model$finalModel$booster) |> as_tibble() |>
  mutate(rank = row_number())
protected_importance <- imp |> filter(str_detect(Feature, "CODE_GENDER|NAME_EDUCATION_TYPE|age_"))

# -----------------------------------------------------------------------------
# 7. Figures (validated categorical slots 1-2; direct labels + tables back them)
# -----------------------------------------------------------------------------
theme_card <- theme_minimal(base_size = 11) +
  theme(panel.grid.minor = element_blank(), panel.grid.major = element_line(colour = "grey90"),
        plot.background = element_rect(fill = "#fcfcfb", colour = NA),
        text = element_text(colour = "#0b0b0b"), axis.text = element_text(colour = "#52514e"),
        legend.position = "top")
roc_h <- roc(y, holdout$prob_platt, levels = c(0, 1), direction = "<", quiet = TRUE)
roc_o <- roc(oof$TARGET, oof$prob_platt_cf, levels = c(0, 1), direction = "<", quiet = TRUE)
roc_df <- bind_rows(tibble(fpr = 1 - roc_h$specificities, tpr = roc_h$sensitivities,
                           curve = sprintf("Holdout (AUC %.4f)", as.numeric(auc(roc_h)))),
                    tibble(fpr = 1 - roc_o$specificities, tpr = roc_o$sensitivities,
                           curve = sprintf("Development OOF (AUC %.4f)", as.numeric(auc(roc_o)))))
op <- threshold_results |> filter(set == "Holdout")
g_roc <- ggplot(roc_df, aes(fpr, tpr, colour = curve, linetype = curve)) +
  geom_abline(linetype = "dashed", colour = "grey60") +
  geom_line(linewidth = 0.8) +
  annotate("point", x = op$fpr, y = op$recall, size = 3, colour = "#0b0b0b") +
  annotate("text", x = op$fpr + 0.03, y = op$recall, hjust = 0, size = 3.2,
           label = sprintf("t = 0.25: recall %.1f%%, FPR %.1f%%", 100 * op$recall, 100 * op$fpr)) +
  scale_colour_manual(values = c("#2a78d6", "#eb6834")) +
  scale_linetype_manual(values = c("longdash", "solid")) +
  coord_equal() +
  labs(x = "False positive rate", y = "True positive rate (recall)", colour = NULL, linetype = NULL,
       title = "ROC: untouched holdout vs development OOF") +
  theme_card + guides(colour = guide_legend(nrow = 2))
ggsave(file.path(out_dir, "step5_roc_holdout.png"), g_roc, width = 6.5, height = 6.8, dpi = 150)

g_rel <- reliability_bins |>
  ggplot(aes(mean_pred, observed)) +
  geom_abline(linetype = "dashed", colour = "grey50") +
  geom_vline(xintercept = THRESHOLD, linetype = "dotted", colour = "grey40") +
  geom_errorbar(aes(ymin = observed_lo, ymax = observed_hi), width = 0, colour = "grey55") +
  geom_point(colour = "#2a78d6", size = 1.8) + geom_line(colour = "#2a78d6") +
  facet_wrap(~ score) + coord_equal(xlim = c(0, 0.5), ylim = c(0, 0.5)) +
  labs(x = "Mean predicted probability (bin)", y = "Observed TARGET = 1 rate (bin)",
       title = "Holdout reliability: raw vs frozen Platt calibration",
       subtitle = "20 equal-count bins (~3,075 applicants each); Wilson 95% intervals; dotted: t = 0.25") +
  theme_card
ggsave(file.path(out_dir, "step5_reliability_holdout.png"), g_rel, width = 9, height = 4.8, dpi = 150)

fair_long <- fairness |>
  select(attribute, group, n, small_sample_flag,
         approval_rate, approval_lo, approval_hi, fpr, fpr_lo, fpr_hi, recall, recall_lo, recall_hi) |>
  pivot_longer(c(approval_rate, fpr, recall), names_to = "metric", values_to = "value") |>
  mutate(lo = case_when(metric == "approval_rate" ~ approval_lo, metric == "fpr" ~ fpr_lo, TRUE ~ recall_lo),
         hi = case_when(metric == "approval_rate" ~ approval_hi, metric == "fpr" ~ fpr_hi, TRUE ~ recall_hi),
         metric = recode(metric, approval_rate = "Approval rate", fpr = "False positive rate (TARGET = 0 declined)",
                         recall = "Recall (TARGET = 1 declined)"),
         label = paste0(group, " (n = ", scales::comma(n), if_else(small_sample_flag, ", small", ""), ")"))
g_fair <- ggplot(fair_long, aes(value, fct_rev(label))) +
  geom_errorbarh(aes(xmin = lo, xmax = hi), height = 0, colour = "grey55") +
  geom_point(aes(shape = small_sample_flag), colour = "#2a78d6", size = 2.4) +
  scale_shape_manual(values = c(`FALSE` = 16, `TRUE` = 1), labels = c("n >= 1,000 and >= 100 events", "Small sample"), name = NULL) +
  facet_grid(attribute ~ metric, scales = "free", space = "free_y") +
  scale_x_continuous(labels = scales::percent) +
  labs(x = NULL, y = NULL, title = "Holdout outcomes by group at the frozen threshold (t = 0.25)",
       subtitle = "Wilson 95% intervals. Differences are descriptive and do not by themselves establish discrimination.") +
  theme_card + theme(strip.text.y = element_text(angle = 0))
ggsave(file.path(out_dir, "step5_fairness_by_group.png"), g_fair, width = 12, height = 5, dpi = 150)

# -----------------------------------------------------------------------------
# 8. Save tables and metadata
# -----------------------------------------------------------------------------
write_csv(isolation_checks, file.path(out_dir, "step5_isolation_checks.csv"))
write_csv(alignment_checks, file.path(out_dir, "step5_alignment_checks.csv"))
write_csv(param_comparison, file.path(out_dir, "step5_prep_params_vs_global.csv"))
write_csv(probability_metrics, file.path(out_dir, "step5_probability_metrics.csv"))
write_csv(threshold_results, file.path(out_dir, "step5_threshold_results.csv"))
write_csv(reliability_bins, file.path(out_dir, "step5_reliability_bins.csv"))
write_csv(risk_bands, file.path(out_dir, "step5_risk_bands.csv"))
write_csv(financial_results, file.path(out_dir, "step5_financial_results.csv"))
write_csv(financial_36_at_own_pstar, file.path(out_dir, "step5_financial_36m_at_own_pstar_descriptive.csv"))
write_csv(bootstrap_ci, file.path(out_dir, "step5_bootstrap_ci.csv"))
write_csv(fairness, file.path(out_dir, "step5_fairness_groups.csv"))
write_csv(protected_in_model, file.path(out_dir, "step5_protected_attributes_in_model.csv"))
write_csv(protected_importance, file.path(out_dir, "step5_protected_attribute_importance.csv"))
saveRDS(list(created = format(Sys.time(), tz = "UTC", usetz = TRUE), threshold = THRESHOLD,
             platt = c(a = a, b = b), fit_seed = 6493, fit_seconds = unname(t_fit),
             hyperparameters = final_params, reproduction_auc_global_prep = repro_auc,
             delong_dev_only_vs_global_prep = roc_test, bootstrap_B = B, bootstrap_seed = 55,
             versions = list(R = R.version.string, xgboost = as.character(packageVersion("xgboost")),
                             caret = as.character(packageVersion("caret")))),
        file.path(out_dir, "step5_metadata.rds"))
writeLines(capture.output(sessionInfo()), file.path(out_dir, "step5_session_info.txt"))

# -----------------------------------------------------------------------------
# 9. Console report
# -----------------------------------------------------------------------------
options(width = 220, pillar.sigfig = 5)
cat("\n== Parameter comparison (dev-only vs global) ==\n"); print(param_comparison)
cat("\nReproduction check AUC (global prep, seed 6493):", sprintf("%.4f", repro_auc), "\n")
cat("DeLong paired test dev-only vs global prep: p =", signif(roc_test$p.value, 3), "\n")
cat("\n== Probability metrics ==\n"); print(as.data.frame(probability_metrics), digits = 5)
cat("\n== Threshold results ==\n"); print(as.data.frame(threshold_results), digits = 4)
cat("\n== Risk bands (holdout) ==\n"); print(as.data.frame(risk_bands), digits = 4)
cat("\n== Financial results ==\n"); print(as.data.frame(financial_results |> select(set, scenario, term_months, G, L, p_star, approved,
  profit_per_applicant_usd, profit_per_approved_usd, profit_total_usd, approve_all_per_applicant_usd,
  improvement_per_applicant_usd, improvement_total_usd, avoided_proxy_losses_usd, foregone_margin_usd)), digits = 5)
cat("\n== 36-month at own p* (descriptive) ==\n"); print(as.data.frame(financial_36_at_own_pstar |> select(threshold, approved, improvement_per_applicant_usd, improvement_total_usd)), digits = 5)
cat("\n== Bootstrap CIs ==\n"); print(as.data.frame(bootstrap_ci), digits = 4)
cat("\n== Fairness ==\n"); print(as.data.frame(fairness |> select(attribute, group, n, events, small_sample_flag, approval_rate, approval_lo, approval_hi,
  decline_rate, observed_rate, recall, fpr, precision, mean_platt, calibration_gap, approval_diff_vs_ref, approval_diff_lo, approval_diff_hi,
  approval_ratio_vs_ref, fpr_diff_vs_ref, recall_diff_vs_ref)), digits = 4)
cat("\n== Protected attributes in model ==\n"); print(protected_in_model); print(protected_importance, n = 30)
cat("\nTotal encoded features used:", nrow(imp), "\n")
