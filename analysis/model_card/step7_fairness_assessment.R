# Step 7 of the model card: detailed fairness analysis on the untouched holdout
# at the frozen threshold (0.25, Platt-calibrated), plus inputs for the
# deployment-readiness assessment.
#
# * Uses saved Step 5 holdout predictions; the model, calibration and threshold
#   are NOT changed. Alternative thresholds are descriptive sensitivity only.
# * Direct-attribute decomposition uses TreeSHAP from the Step 5
#   development-only model on the holdout (the same model that produced the
#   holdout predictions). Removing a SHAP term is a descriptive accounting of
#   the model's direct use of an attribute, NOT a retrained model without it.
# * TARGET = 1 means payment difficulty, not a confirmed write-off.
#
#   "C:/Program Files/R/R-4.5.2/bin/Rscript.exe" analysis/model_card/step7_fairness_assessment.R

suppressPackageStartupMessages({ library(tidyverse); library(caret); library(xgboost); library(pROC) })
out_dir <- "models/model_card"
THRESHOLD <- 0.25
source("data_preparation.R")  # functions only

# -----------------------------------------------------------------------------
# 1. Load and verify Step 5 results
# -----------------------------------------------------------------------------
h <- readRDS(file.path(out_dir, "step5_holdout_predictions.rds"))
step5_groups <- read_csv(file.path(out_dir, "step5_fairness_groups.csv"), show_col_types = FALSE)
calib <- readRDS(file.path(out_dir, "step3_calibrators.rds"))
a <- calib$platt$coefficients[[1]]; b <- calib$platt$coefficients[[2]]
stopifnot(nrow(h) == 61502, sum(h$TARGET) == 4965)

raw <- load_raw_data("homecredit-eda/data")
bureau_agg <- aggregate_bureau(raw$bureau)
extra <- raw$train |> filter(SK_ID_CURR %in% h$SK_ID_CURR) |>
  transmute(SK_ID_CURR, NAME_FAMILY_STATUS, age_years = -DAYS_BIRTH / 365.25)
raw_hold <- raw$train |> filter(SK_ID_CURR %in% h$SK_ID_CURR)
rm(raw); invisible(gc())
h <- h |> left_join(extra, by = "SK_ID_CURR") |>
  mutate(approve = prob_platt < THRESHOLD,
         age_group = cut(age_years, c(-Inf, 30, 40, 50, 62, Inf), right = FALSE,
                         labels = c("< 30", "30-39", "40-49", "50-61", "62+")))

wilson <- function(x, n, z = 1.96) {
  if (is.na(n) || n == 0) return(c(NA_real_, NA_real_))
  p <- x / n; d <- 1 + z^2 / n
  c0 <- (p + z^2 / (2 * n)) / d; hw <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / d
  c(c0 - hw, c0 + hw)
}

# -----------------------------------------------------------------------------
# 2. Group metrics at the frozen threshold
# -----------------------------------------------------------------------------
group_table <- function(df, attr) {
  df |> group_by(group = .data[[attr]]) |>
    group_modify(function(d, k) {
      y <- d$TARGET; p <- d$prob_platt; ap <- d$approve
      tp <- sum(!ap & y == 1); fp <- sum(!ap & y == 0); tn <- sum(ap & y == 0); fn <- sum(ap & y == 1)
      ev <- sum(y); ne <- sum(y == 0); n <- nrow(d)
      auc_ok <- ev >= 30 && ne >= 30
      au <- if (auc_ok) ci.auc(roc(y, p, levels = c(0, 1), direction = "<", quiet = TRUE), method = "delong") else rep(NA_real_, 3)
      cal_ok <- ev >= 100
      cal <- if (cal_ok) {
        lp <- qlogis(p)
        s <- glm(y ~ lp, family = binomial()); i <- glm(y ~ 1, offset = lp, family = binomial())
        c(coef(i)[1], confint.default(i)[1, ], coef(s)[2], confint.default(s)[2, ])
      } else rep(NA_real_, 6)
      tibble(n = n, events = ev, approved = tn + fn, declined = tp + fp,
             approval_rate = (tn + fn) / n, approval_lo = wilson(tn + fn, n)[1], approval_hi = wilson(tn + fn, n)[2],
             decline_rate = (tp + fp) / n,
             prevalence = ev / n, prevalence_lo = wilson(ev, n)[1], prevalence_hi = wilson(ev, n)[2],
             fpr = fp / ne, fpr_lo = wilson(fp, ne)[1], fpr_hi = wilson(fp, ne)[2],
             tpr = if (ev > 0) tp / ev else NA_real_, tpr_lo = wilson(tp, ev)[1], tpr_hi = wilson(tp, ev)[2],
             precision = if (tp + fp >= 30) tp / (tp + fp) else NA_real_,
             precision_lo = if (tp + fp >= 30) wilson(tp, tp + fp)[1] else NA_real_,
             precision_hi = if (tp + fp >= 30) wilson(tp, tp + fp)[2] else NA_real_,
             approval_rate_among_target0 = tn / ne,
             auc = au[2], auc_lo = au[1], auc_hi = au[3],
             mean_pred = mean(p), calibration_in_large_gap = mean(p) - ev / n,
             cal_intercept = cal[1], cal_intercept_lo = cal[2], cal_intercept_hi = cal[3],
             cal_slope = cal[4], cal_slope_lo = cal[5], cal_slope_hi = cal[6],
             reliability = case_when(n < 100 | ev < 10 ~ "Unreliable (too few applicants or events)",
                                     n < 1000 | ev < 100 ~ "Limited (small group)",
                                     TRUE ~ "Adequate"))
    }) |> ungroup() |> mutate(attribute = attr, .before = 1)
}
groups <- bind_rows(group_table(h, "CODE_GENDER"), group_table(h, "NAME_EDUCATION_TYPE"),
                    group_table(h, "NAME_FAMILY_STATUS"), group_table(h, "age_group"))

# Verify against Step 5 and the figures quoted in the Step 7 brief.
chk <- function(attr, g, col) groups[[col]][groups$attribute == attr & groups$group == g]
verification <- tibble(
  Check = c("F approval 96.3%", "F FPR 2.7%", "M approval 92.4%", "M FPR 5.6%", "Gender approval gap 3.9 pp",
            "Higher education approval 98.1% (14,819/15,099 = 98.146%; the 98.2% quoted in Step 5 was a double-rounding error)",
            "Secondary approval 93.9%", "Academic degree n = 37, 1 event",
            "Matches Step 5 table (approval, FPR, recall) for all gender/education groups"),
  Passed = c(round(100 * chk("CODE_GENDER", "F", "approval_rate"), 1) == 96.3,
             round(100 * chk("CODE_GENDER", "F", "fpr"), 1) == 2.7,
             round(100 * chk("CODE_GENDER", "M", "approval_rate"), 1) == 92.4,
             round(100 * chk("CODE_GENDER", "M", "fpr"), 1) == 5.6,
             round(100 * (chk("CODE_GENDER", "F", "approval_rate") - chk("CODE_GENDER", "M", "approval_rate")), 1) == 3.9,
             round(100 * chk("NAME_EDUCATION_TYPE", "Higher education", "approval_rate"), 1) == 98.1,
             round(100 * chk("NAME_EDUCATION_TYPE", "Secondary / secondary special", "approval_rate"), 1) == 93.9,
             chk("NAME_EDUCATION_TYPE", "Academic degree", "n") == 37 && chk("NAME_EDUCATION_TYPE", "Academic degree", "events") == 1,
             {
               j <- inner_join(filter(groups, attribute %in% c("CODE_GENDER", "NAME_EDUCATION_TYPE")),
                               step5_groups, by = c("attribute", "group"), suffix = c("", ".s5"))
               nrow(j) == 7 && max(abs(j$approval_rate - j$approval_rate.s5), abs(j$fpr - j$fpr.s5),
                                   abs(j$tpr - j$recall), na.rm = TRUE) < 1e-12
             }))
print(verification)
stopifnot(all(verification$Passed))

# -----------------------------------------------------------------------------
# 3. Disparities with bootstrap CIs (B = 1,000, applicant-level, resampled within each group)
# -----------------------------------------------------------------------------
comparisons <- tribble(
  ~attribute, ~group, ~reference,
  "CODE_GENDER", "M", "F",
  "NAME_EDUCATION_TYPE", "Secondary / secondary special", "Higher education",
  "NAME_EDUCATION_TYPE", "Incomplete higher", "Higher education",
  "NAME_EDUCATION_TYPE", "Lower secondary", "Higher education",
  "NAME_EDUCATION_TYPE", "Academic degree", "Higher education",
  "NAME_FAMILY_STATUS", "Single / not married", "Married",
  "NAME_FAMILY_STATUS", "Civil marriage", "Married",
  "NAME_FAMILY_STATUS", "Separated", "Married",
  "NAME_FAMILY_STATUS", "Widow", "Married",
  "age_group", "< 30", "40-49",
  "age_group", "62+", "40-49")
metric_fun <- function(y, ap) {
  ne <- sum(y == 0); ev <- sum(y == 1)
  c(approval = mean(ap), fpr = sum(!ap & y == 0) / ne, tpr = if (ev > 0) sum(!ap & y == 1) / ev else NA_real_,
    prevalence = mean(y))
}
B <- 1000; set.seed(77)
disparities <- pmap_dfr(comparisons, function(attribute, group, reference) {
  g <- h[as.character(h[[attribute]]) == group, ]; r <- h[as.character(h[[attribute]]) == reference, ]
  est_g <- metric_fun(g$TARGET, g$approve); est_r <- metric_fun(r$TARGET, r$approve)
  boots <- replicate(B, {
    ig <- sample.int(nrow(g), replace = TRUE); ir <- sample.int(nrow(r), replace = TRUE)
    metric_fun(g$TARGET[ig], g$approve[ig]) - metric_fun(r$TARGET[ir], r$approve[ir])
  })
  ratio_boot <- replicate(500, { ig <- sample.int(nrow(g), replace = TRUE); ir <- sample.int(nrow(r), replace = TRUE)
    mean(g$approve[ig]) / mean(r$approve[ir]) })
  tibble(attribute, group, reference, n_group = nrow(g), n_reference = nrow(r), events_group = sum(g$TARGET),
         metric = names(est_g), group_value = est_g, reference_value = est_r, difference = est_g - est_r,
         diff_lo = apply(boots, 1, quantile, 0.025, na.rm = TRUE), diff_hi = apply(boots, 1, quantile, 0.975, na.rm = TRUE)) |>
    mutate(approval_ratio = if_else(metric == "approval", est_g[["approval"]] / est_r[["approval"]], NA_real_),
           ratio_lo = if_else(metric == "approval", quantile(ratio_boot, 0.025), NA_real_),
           ratio_hi = if_else(metric == "approval", quantile(ratio_boot, 0.975), NA_real_),
           ci_excludes_zero = diff_lo > 0 | diff_hi < 0,
           unstable = n_group < 1000 | events_group < 100)
})
auc_tests <- pmap_dfr(filter(comparisons, attribute %in% c("CODE_GENDER", "NAME_EDUCATION_TYPE")), function(attribute, group, reference) {
  g <- h[as.character(h[[attribute]]) == group, ]; r <- h[as.character(h[[attribute]]) == reference, ]
  if (sum(g$TARGET) < 30) return(tibble(attribute, group, reference, auc_group = NA_real_, auc_reference = NA_real_, p_value = NA_real_))
  rg <- roc(g$TARGET, g$prob_platt, levels = c(0, 1), direction = "<", quiet = TRUE)
  rr <- roc(r$TARGET, r$prob_platt, levels = c(0, 1), direction = "<", quiet = TRUE)
  tt <- roc.test(rg, rr, method = "delong", paired = FALSE)
  tibble(attribute, group, reference, auc_group = as.numeric(auc(rg)), auc_reference = as.numeric(auc(rr)), p_value = tt$p.value)
})

# -----------------------------------------------------------------------------
# 4. Direct-attribute decomposition on the holdout (dev-only model TreeSHAP)
# -----------------------------------------------------------------------------
dev_model  <- readRDS(file.path(out_dir, "step5_dev_only_xgb.rds"))
dev_params <- readRDS(file.path(out_dir, "step5_dev_only_prep_params.rds"))
prep_hold  <- prepare_application(raw_hold, bureau_agg, params = dev_params)$data
prep_hold  <- prep_hold[match(h$SK_ID_CURR, prep_hold$SK_ID_CURR), ]
terms_x <- delete.response(dev_model$terms)
Xf <- model.matrix(terms_x, model.frame(terms_x, select(prep_hold, -SK_ID_CURR, -TARGET), xlev = dev_model$xlevels),
                   contrasts.arg = dev_model$contrasts)
src <- attr(terms_x, "term.labels")[attr(Xf, "assign")[-1]]
X <- Xf[, -1]
contrib <- predict(dev_model$finalModel$booster, X, predcontrib = TRUE)
stopifnot(max(abs(plogis(rowSums(contrib)) - h$prob_raw)) < 1e-6)
sh <- contrib[, colnames(contrib) != "(Intercept)"]
by_var <- function(v) rowSums(sh[, src == v, drop = FALSE])
f_lo <- rowSums(contrib)
platt <- function(lo) plogis(a + b * qlogis(plogis(lo)))
direct_terms <- list(
  "Gender (CODE_GENDER)" = by_var("CODE_GENDER"),
  "Marital status (NAME_FAMILY_STATUS)" = by_var("NAME_FAMILY_STATUS"),
  "Education (NAME_EDUCATION_TYPE)" = by_var("NAME_EDUCATION_TYPE"),
  "Age, direct (age_years + age_band)" = by_var("age_years") + by_var("age_band"),
  "Age-derived (ext_mean_x_age + employed_share_of_life)" = by_var("ext_mean_x_age") + by_var("employed_share_of_life"))
direct_terms[["Gender + marital status"]] <- direct_terms[[1]] + direct_terms[[2]]
direct_terms[["All of the above"]] <- Reduce(`+`, direct_terms[1:5])

gap <- function(ap, attr, g, r) mean(ap[h[[attr]] == r]) - mean(ap[h[[attr]] == g])
decomp <- imap_dfr(direct_terms, function(term, nm) {
  ap_wo <- platt(f_lo - term) < THRESHOLD
  bind_rows(
    tibble(comparison = "Approval gap F - M", attr = "CODE_GENDER", g = "M", r = "F"),
    tibble(comparison = "Approval gap Higher - Secondary", attr = "NAME_EDUCATION_TYPE", g = "Secondary / secondary special", r = "Higher education"),
    tibble(comparison = "Approval gap Married - Single", attr = "NAME_FAMILY_STATUS", g = "Single / not married", r = "Married")) |>
    mutate(term_removed = nm,
           gap_actual = pmap_dbl(list(attr, g, r), ~ gap(h$approve, ..1, ..2, ..3)),
           gap_without_term = pmap_dbl(list(attr, g, r), ~ gap(ap_wo, ..1, ..2, ..3)),
           overall_approval_without_term = mean(ap_wo))
}) |> mutate(share_of_gap_from_term = (gap_actual - gap_without_term) / gap_actual)
direct_effect_by_group <- imap_dfr(direct_terms[1:5], function(term_values, nm) {
  pp <- platt(f_lo) - platt(f_lo - term_values)
  bind_rows(
    tibble(term = nm, attribute = "CODE_GENDER", group = h$CODE_GENDER, lo = term_values, pp = pp),
    tibble(term = nm, attribute = "NAME_EDUCATION_TYPE", group = h$NAME_EDUCATION_TYPE, lo = term_values, pp = pp),
    tibble(term = nm, attribute = "NAME_FAMILY_STATUS", group = h$NAME_FAMILY_STATUS, lo = term_values, pp = pp),
    tibble(term = nm, attribute = "age_group", group = as.character(h$age_group), lo = term_values, pp = pp))
}) |>
  filter((term == "Gender (CODE_GENDER)" & attribute == "CODE_GENDER") |
         (term == "Education (NAME_EDUCATION_TYPE)" & attribute == "NAME_EDUCATION_TYPE") |
         (term == "Marital status (NAME_FAMILY_STATUS)" & attribute == "NAME_FAMILY_STATUS") |
         (str_starts(term, "Age") & attribute == "age_group")) |>
  group_by(term, attribute, group) |>
  summarise(n = n(), mean_logodds = mean(lo), mean_pp_calibrated = mean(pp),
            share_risk_raising = mean(lo > 0), .groups = "drop")
elderly_holdout <- tibble(
  elderly_n = sum(h$age_years >= 62),
  direct_age_positive = sum((direct_terms[[4]] > 0)[h$age_years >= 62]),
  direct_plus_derived_positive = sum(((direct_terms[[4]] + direct_terms[[5]]) > 0)[h$age_years >= 62]),
  max_direct_pp = max((platt(f_lo) - platt(f_lo - direct_terms[[4]]))[h$age_years >= 62]))

# Proxy screen: how well does each influential encoded feature, alone,
# separate men from women / higher education from others? (AUC distance from 0.5)
top_feats <- names(sort(colMeans(abs(sh)), decreasing = TRUE))[1:40]
top_feats <- setdiff(top_feats, grep("^CODE_GENDER|^NAME_EDUCATION_TYPE", top_feats, value = TRUE))
proxy_auc <- function(target) map_dbl(top_feats, function(f)
  abs(as.numeric(auc(roc(target, X[, f], levels = c(FALSE, TRUE), direction = "<", quiet = TRUE))) - 0.5) + 0.5)
proxy <- tibble(feature = top_feats, source_variable = src[match(top_feats, colnames(X))],
                mean_abs_shap_holdout = colMeans(abs(sh))[top_feats],
                auc_separating_male = proxy_auc(h$CODE_GENDER == "M"),
                auc_separating_higher_educ = proxy_auc(h$NAME_EDUCATION_TYPE == "Higher education")) |>
  mutate(proxy_strength_gender = case_when(auc_separating_male >= 0.70 ~ "Strong", auc_separating_male >= 0.60 ~ "Moderate", TRUE ~ "Weak"),
         proxy_strength_education = case_when(auc_separating_higher_educ >= 0.70 ~ "Strong", auc_separating_higher_educ >= 0.60 ~ "Moderate", TRUE ~ "Weak")) |>
  arrange(desc(pmax(auc_separating_male, auc_separating_higher_educ)))

# -----------------------------------------------------------------------------
# 5. Threshold sensitivity (descriptive only; threshold stays 0.25)
# -----------------------------------------------------------------------------
sens_thresholds <- c(0.15, 0.20, 0.25, 0.30, 0.35)
sensitivity <- map_dfr(sens_thresholds, function(t) {
  h |> mutate(ap = prob_platt < t) |>
    pivot_longer(c(CODE_GENDER, NAME_EDUCATION_TYPE), names_to = "attribute", values_to = "group") |>
    group_by(attribute, group) |>
    summarise(n = n(), approval = mean(ap), fpr = sum(!ap & TARGET == 0) / sum(TARGET == 0),
              tpr = sum(!ap & TARGET == 1) / sum(TARGET == 1), .groups = "drop") |>
    mutate(threshold = t, overall_approval = mean(h$prob_platt < t))
})
sensitivity_gaps <- sensitivity |>
  filter(group %in% c("F", "M", "Higher education", "Secondary / secondary special")) |>
  select(threshold, attribute, group, approval, fpr, tpr, overall_approval) |>
  pivot_wider(names_from = group, values_from = c(approval, fpr, tpr)) |>
  group_by(threshold, overall_approval) |>
  summarise(
    gender_approval_gap_pp = 100 * (max(approval_F, na.rm = TRUE) - max(approval_M, na.rm = TRUE)),
    gender_approval_ratio_M_over_F = max(approval_M, na.rm = TRUE) / max(approval_F, na.rm = TRUE),
    gender_fpr_ratio_M_over_F = max(fpr_M, na.rm = TRUE) / max(fpr_F, na.rm = TRUE),
    gender_fpr_gap_pp = 100 * (max(fpr_M, na.rm = TRUE) - max(fpr_F, na.rm = TRUE)),
    gender_tpr_gap_pp = 100 * (max(tpr_M, na.rm = TRUE) - max(tpr_F, na.rm = TRUE)),
    educ_approval_gap_pp = 100 * (max(`approval_Higher education`, na.rm = TRUE) - max(`approval_Secondary / secondary special`, na.rm = TRUE)),
    educ_approval_ratio_sec_over_higher = max(`approval_Secondary / secondary special`, na.rm = TRUE) / max(`approval_Higher education`, na.rm = TRUE),
    educ_fpr_ratio_sec_over_higher = max(`fpr_Secondary / secondary special`, na.rm = TRUE) / max(`fpr_Higher education`, na.rm = TRUE),
    .groups = "drop") |>
  mutate(note = if_else(threshold == THRESHOLD, "Frozen research threshold", "Sensitivity only - not a selection"))

# -----------------------------------------------------------------------------
# 6. Figures
# -----------------------------------------------------------------------------
theme_card <- theme_minimal(base_size = 11) +
  theme(panel.grid.minor = element_blank(), panel.grid.major = element_line(colour = "grey90"),
        plot.background = element_rect(fill = "#fcfcfb", colour = NA), plot.title.position = "plot",
        text = element_text(colour = "#0b0b0b"), axis.text = element_text(colour = "#52514e"), legend.position = "top")

gm <- groups |> filter(attribute %in% c("CODE_GENDER", "NAME_EDUCATION_TYPE")) |>
  mutate(label = paste0(group, " (n = ", scales::comma(n), ")"),
         unstable = reliability != "Adequate")
long <- bind_rows(
  transmute(gm, attribute, label, unstable, metric = "Approval rate", v = approval_rate, lo = approval_lo, hi = approval_hi),
  transmute(gm, attribute, label, unstable, metric = "Observed payment-difficulty rate", v = prevalence, lo = prevalence_lo, hi = prevalence_hi),
  transmute(gm, attribute, label, unstable, metric = "False positive rate (TARGET = 0 declined)", v = fpr, lo = fpr_lo, hi = fpr_hi),
  transmute(gm, attribute, label, unstable, metric = "True positive rate (TARGET = 1 declined)", v = tpr, lo = tpr_lo, hi = tpr_hi),
  transmute(gm, attribute, label, unstable, metric = "Group AUC", v = auc, lo = auc_lo, hi = auc_hi)) |>
  mutate(metric = factor(metric, unique(metric)))
g1 <- ggplot(long, aes(v, fct_rev(label))) +
  geom_errorbar(aes(xmin = lo, xmax = hi), width = 0, colour = "grey55", orientation = "y", na.rm = TRUE) +
  geom_point(aes(shape = unstable), colour = "#2a78d6", size = 2.4, na.rm = TRUE) +
  scale_shape_manual(values = c(`FALSE` = 16, `TRUE` = 1), labels = c("Adequate sample", "Small / unstable group"), name = NULL) +
  facet_grid(attribute ~ metric, scales = "free", space = "free_y", labeller = label_wrap_gen(22)) +
  scale_x_continuous(labels = function(x) ifelse(x <= 1, scales::percent(x, 1), x)) +
  labs(x = NULL, y = NULL, title = "Holdout fairness metrics by group at the frozen threshold (t = 0.25)",
       subtitle = "Wilson / DeLong 95% intervals; AUC omitted where a group has fewer than 30 events. Academic degree (n = 37, 1 event) is not interpretable.") +
  theme_card + theme(strip.text.y = element_text(angle = 0), axis.text.x = element_text(size = 8))
ggsave(file.path(out_dir, "step7_group_metrics.png"), g1, width = 14, height = 5.2, dpi = 150)

g2 <- sensitivity |> filter(group %in% c("F", "M", "Higher education", "Secondary / secondary special")) |>
  pivot_longer(c(approval, fpr, tpr), names_to = "metric") |>
  mutate(metric = recode(metric, approval = "Approval rate", fpr = "False positive rate", tpr = "True positive rate"),
         pair = if_else(attribute == "CODE_GENDER", "Gender", "Education")) |>
  ggplot(aes(threshold, value, colour = group, linetype = group)) +
  geom_vline(xintercept = THRESHOLD, linetype = "dotted", colour = "grey40") +
  geom_line(linewidth = 0.8) + geom_point(size = 1.6) +
  facet_grid(metric ~ pair, scales = "free_y") +
  scale_colour_manual(values = c(F = "#2a78d6", M = "#eb6834", `Higher education` = "#2a78d6", `Secondary / secondary special` = "#eb6834")) +
  scale_linetype_manual(values = c(F = "solid", M = "longdash", `Higher education` = "solid", `Secondary / secondary special` = "longdash")) +
  scale_y_continuous(labels = scales::percent) +
  labs(x = "Threshold (Platt-calibrated probability) - sensitivity only; frozen threshold dotted", y = NULL, colour = NULL, linetype = NULL,
       title = "Threshold sensitivity of group outcomes on the holdout (descriptive)") +
  theme_card
ggsave(file.path(out_dir, "step7_threshold_sensitivity.png"), g2, width = 10, height = 7, dpi = 150)

g3 <- decomp |> filter(term_removed %in% c("Gender (CODE_GENDER)", "Education (NAME_EDUCATION_TYPE)", "Marital status (NAME_FAMILY_STATUS)", "All of the above")) |>
  select(comparison, term_removed, `Actual gap` = gap_actual, `Gap without the model's direct term` = gap_without_term) |>
  pivot_longer(c(`Actual gap`, `Gap without the model's direct term`)) |>
  ggplot(aes(100 * value, term_removed, fill = name)) +
  geom_col(position = position_dodge(width = 0.7), width = 0.6) +
  geom_text(aes(label = sprintf("%.1f pp", 100 * value)), position = position_dodge(width = 0.7), hjust = -0.1, size = 3) +
  facet_wrap(~ comparison, ncol = 1) +
  scale_fill_manual(values = c(`Actual gap` = "#2a78d6", `Gap without the model's direct term` = "#eb6834"), name = NULL) +
  scale_x_continuous(expand = expansion(mult = c(0, 0.15))) +
  labs(x = "Approval-rate gap (percentage points)", y = "Direct SHAP term removed",
       title = "How much of each approval gap comes from the model's direct use of the attribute?",
       subtitle = "Holdout, dev-only model TreeSHAP; descriptive accounting, not a retrained model (correlated features could absorb some effect).") +
  theme_card
ggsave(file.path(out_dir, "step7_direct_term_decomposition.png"), g3, width = 10, height = 7.5, dpi = 150)

# -----------------------------------------------------------------------------
# 7. Deployment risk register
# -----------------------------------------------------------------------------
risk_register <- tribble(
  ~risk, ~rating, ~evidence, ~mitigation_or_validation,
  "Direct use of gender and marital status", "Critical",
  "CODE_GENDER is the #4 variable by SHAP; it raises predicted risk for every male applicant. Marital status is also a direct input. Both are prohibited bases under 12 CFR 1002.2(z) / 1002.6(b).",
  "Remove both; rebuild and re-validate a candidate model; legal sign-off before any use.",
  "Age-related restrictions", "Critical",
  "age_years, age_band, ext_mean_x_age and employed_share_of_life use age; some elderly (62+) applicants receive a risk-raising age contribution, which 12 CFR 1002.6(b)(2)(ii) does not allow.",
  "Remove age or constrain it (e.g., monotone so elderly are never disfavored); legal review of age-derived features.",
  "Unexplained external credit scores", "Critical",
  "EXT_SOURCE family is ~half of model attribution and the main reason for ~98% of would-be declines; provider, inputs and meaning are undocumented.",
  "Obtain vendor documentation, permissible-purpose and data-accuracy assurances; otherwise exclude.",
  "Missing valid adverse-action explanations", "Critical",
  "Principal reasons for most declines are undocumented scores or prohibited bases; generic checklist reasons are insufficient (CFPB Circ. 2022-03, 2023-03; 12 CFR 1002.9(b)(2)).",
  "Build and test a reason-code process on the compliant model; legal and customer-communication review.",
  "Education disparities", "High",
  "Education is the #5 variable; Higher-education approval 98.1% vs Secondary 93.9%; FPR 1.4% vs 4.4%.",
  "Document business justification; test less-discriminatory alternatives; monitor outcomes by education.",
  "Proxy discrimination", "High",
  "Several influential features differ by gender/education (see step7_proxy_screen.csv); removing direct terms will not remove all group differences.",
  "Proxy analysis and disparate-impact testing on the compliant model; review car ownership, income type, ID recency, social-circle data.",
  "Labels are payment difficulty, not losses", "High",
  "TARGET = 1 is late payment within the first Y installments; X and Y undisclosed; loss conversion c unsourced.",
  "Re-label with observed charge-off and recovery outcomes; validate c, LGD, EAD.",
  "Loan-term and financial-assumption uncertainty", "High",
  "Base-case gain +$15.8/applicant at 24 months but ~+$0.8 (CI spans zero) at 36 months; optimal threshold 0.11-0.48 across plausible assumptions.",
  "Use Home Credit's actual pricing, term, funding and cost data; re-derive threshold before any pilot.",
  "Selection bias (outcomes only for approved applicants)", "High",
  "Training data contain past approvals only; performance on previously declined applicants is unknown.",
  "Reject-inference study or controlled pilot with limited exposure; monitor approval-population shift.",
  "Geographic and temporal generalization", "High",
  "Country, currency and period of the data are undisclosed; Home Credit operated in 9 countries; economics used U.S. and 2018 Home Credit figures.",
  "Out-of-time and per-market validation; re-calibrate per market.",
  "Model calibration and generalization", "Medium",
  "Holdout AUC 0.755 vs CV 0.759; Platt slope 0.99 on holdout; calibration similar across gender and education groups.",
  "Re-confirm on out-of-time data; monitor calibration and AUC monthly; recalibration trigger rules.",
  "Monitoring and governance", "Medium",
  "No monitoring, drift detection, override process or model-risk sign-off exists yet.",
  "Model-risk-management review (independent validation), drift/fairness dashboards, human-review process for referrals, documented change control.",
  "Small-group instability", "Low",
  "Academic degree n = 37 (1 event); Lower secondary n = 756; results not interpretable or limited.",
  "Pool or report with uncertainty; collect more data before conclusions."
)
rating_criteria <- tribble(
  ~rating, ~criterion,
  "Critical", "Legally prohibited or restricted practice, or prevents compliant operation (e.g., cannot produce lawful adverse-action notices). Blocks deployment.",
  "High", "Material uncertainty that could change who is approved, the economics, or customer harm; must be resolved or validated before a pilot.",
  "Medium", "Manageable with standard validation, monitoring and governance controls before or during a pilot.",
  "Low", "Limited impact; document and monitor.")

# -----------------------------------------------------------------------------
# 8. Save and report
# -----------------------------------------------------------------------------
write_csv(verification, file.path(out_dir, "step7_verification.csv"))
write_csv(groups, file.path(out_dir, "step7_group_metrics.csv"))
write_csv(disparities, file.path(out_dir, "step7_disparities_bootstrap.csv"))
write_csv(auc_tests, file.path(out_dir, "step7_group_auc_tests.csv"))
write_csv(decomp, file.path(out_dir, "step7_direct_term_decomposition.csv"))
write_csv(direct_effect_by_group, file.path(out_dir, "step7_direct_effect_by_group.csv"))
write_csv(elderly_holdout, file.path(out_dir, "step7_elderly_holdout_check.csv"))
write_csv(proxy, file.path(out_dir, "step7_proxy_screen.csv"))
write_csv(sensitivity, file.path(out_dir, "step7_threshold_sensitivity.csv"))
write_csv(sensitivity_gaps, file.path(out_dir, "step7_threshold_sensitivity_gaps.csv"))
write_csv(risk_register, file.path(out_dir, "step7_deployment_risk_register.csv"))
write_csv(rating_criteria, file.path(out_dir, "step7_risk_rating_criteria.csv"))

options(width = 230, pillar.sigfig = 4)
print(verification)
cat("\n== Groups ==\n"); print(as.data.frame(groups |> select(attribute, group, n, events, approval_rate, prevalence, fpr, tpr, precision, auc, auc_lo, auc_hi,
  mean_pred, calibration_in_large_gap, cal_intercept, cal_slope, cal_slope_lo, cal_slope_hi, reliability)), digits = 4)
cat("\n== Disparities ==\n"); print(as.data.frame(disparities |> select(group, reference, metric, group_value, reference_value, difference, diff_lo, diff_hi, approval_ratio, ratio_lo, ratio_hi, unstable)), digits = 4)
cat("\n== AUC tests ==\n"); print(as.data.frame(auc_tests), digits = 4)
cat("\n== Decomposition ==\n"); print(as.data.frame(decomp |> select(comparison, term_removed, gap_actual, gap_without_term, share_of_gap_from_term, overall_approval_without_term)), digits = 4)
cat("\n== Direct effect by group ==\n"); print(as.data.frame(direct_effect_by_group), digits = 3)
cat("\n== Elderly holdout ==\n"); print(elderly_holdout)
cat("\n== Proxy screen (top 12) ==\n"); print(as.data.frame(head(proxy, 12)), digits = 3)
cat("\n== Sensitivity gaps ==\n"); print(as.data.frame(sensitivity_gaps), digits = 4)
