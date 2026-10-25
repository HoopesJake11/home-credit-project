# Step 6 of the model card: SHAP explainability and adverse-action mapping for
# the ORIGINAL final model (models/final_home_credit_xgb.rds).
#
# * The model was trained on all 307,511 labeled rows, so SHAP here describes
#   FITTED model behavior on applicants it has seen. It says nothing about
#   out-of-sample performance (see Steps 3 and 5 for that).
# * SHAP values come from xgboost's built-in exact TreeSHAP
#   (predict(..., predcontrib = TRUE)). They are additive in LOG-ODDS of
#   TARGET = 1 (payment difficulty), not probability points.
# * 1,000 labeled applicants, sampled reproducibly (seed 20261025).
# * Nothing is retrained or modified. Writes only to models/model_card/.
#
#   "C:/Program Files/R/R-4.5.2/bin/Rscript.exe" analysis/model_card/step6_shap_analysis.R

suppressPackageStartupMessages({ library(tidyverse); library(caret); library(xgboost) })
out_dir <- "models/model_card"

# -----------------------------------------------------------------------------
# 1. Model, data, sample, design matrix
# -----------------------------------------------------------------------------
model    <- readRDS("models/final_home_credit_xgb.rds")
train    <- readRDS("homecredit-eda/data/prepared/train_prepared.rds")
params   <- readRDS("homecredit-eda/data/prepared/prep_params.rds")
dict     <- read_csv("homecredit-eda/data/HomeCredit_columns_description.csv",
                     show_col_types = FALSE, locale = locale(encoding = "latin1")) |>
  filter(Table == "application_{train|test}.csv") |> select(Row, Description)
calib    <- readRDS(file.path(out_dir, "step3_calibrators.rds"))
booster  <- model$finalModel$booster
stopifnot(identical(params$feature_cols, setdiff(names(train), c("SK_ID_CURR", "TARGET"))))

set.seed(20261025)
sample_rows <- sort(sample.int(nrow(train), 1000))
s <- train[sample_rows, ]

# Same encoding caret used at fit time: stored terms, xlevels and contrasts.
terms_x <- delete.response(model$terms)
mf <- model.frame(terms_x, select(s, -SK_ID_CURR, -TARGET), xlev = model$xlevels)
X_full <- model.matrix(terms_x, mf, contrasts.arg = model$contrasts)
assign_idx <- attr(X_full, "assign")[-1]
X <- X_full[, -1, drop = FALSE]
source_var <- attr(terms_x, "term.labels")[assign_idx]
names(source_var) <- colnames(X)

prob_caret  <- predict(model, newdata = select(s, -SK_ID_CURR, -TARGET), type = "prob")$Default
prob_direct <- predict(booster, X)
contrib     <- predict(booster, X, predcontrib = TRUE)
shap <- contrib[, colnames(contrib) != "(Intercept)"]
base_logodds <- unique(round(contrib[, "(Intercept)"], 10))

checks <- tibble(
  Check = c("Encoded columns identical to the model's 300 xNames",
            "Booster probabilities equal caret predict()",
            "SHAP + base value = log-odds of prediction (max abs error)",
            "Single base value (log-odds)",
            "Sample size", "Sample TARGET = 1 rate"),
  Result = c(format(identical(colnames(X), model$finalModel$xNames)),
             format(max(abs(prob_caret - prob_direct)) == 0),
             format(signif(max(abs(rowSums(contrib) - qlogis(prob_direct))), 3)),
             paste0(length(base_logodds) == 1, " (", round(base_logodds, 4), " log-odds = p ",
                    round(plogis(base_logodds), 4), ")"),
             format(nrow(s)), sprintf("%.3f (full data 0.081)", mean(s$TARGET))))
stopifnot(identical(colnames(X), model$finalModel$xNames), max(abs(prob_caret - prob_direct)) == 0,
          max(abs(rowSums(contrib) - qlogis(prob_direct))) < 1e-5)

# -----------------------------------------------------------------------------
# 2. Feature descriptions (data dictionary + data_preparation.R), verified
# -----------------------------------------------------------------------------
ext_note <- "Dictionary: 'Normalized score from external data source'. Provider, inputs and scale are undocumented."
desc_map <- tribble(
  ~feature, ~readable, ~definition,
  "ext_source_mean", "Average external score", paste("Mean of the available EXT_SOURCE_1-3 values (data_preparation.R).", ext_note),
  "ext_source_min", "Lowest external score", paste("Minimum of the available EXT_SOURCE_1-3 values.", ext_note),
  "ext_source_max", "Highest external score", paste("Maximum of the available EXT_SOURCE_1-3 values.", ext_note),
  "EXT_SOURCE_1", "External score 1", ext_note,
  "EXT_SOURCE_2", "External score 2", ext_note,
  "EXT_SOURCE_3", "External score 3", paste(ext_note, "Missing values filled with the training median."),
  "EXT_SOURCE_1_missing", "External score 1 not available", "1 if EXT_SOURCE_1 was blank (56% of applicants) and imputed.",
  "EXT_SOURCE_3_missing", "External score 3 not available", "1 if EXT_SOURCE_3 was blank and imputed.",
  "ext_mean_x_age", "External score x age", "ext_source_mean multiplied by age_years (engineered interaction).",
  "ltv", "Loan-to-value", "AMT_CREDIT / AMT_GOODS_PRICE: loan amount relative to the price of the goods financed (above 1 = fees or insurance financed).",
  "credit_to_annuity", "Loan amount / payment (term proxy)", "AMT_CREDIT / AMT_ANNUITY: roughly the number of payments needed, a proxy for loan term.",
  "AMT_ANNUITY", "Loan payment amount", "Dictionary: 'Loan annuity' (the periodic repayment amount).",
  "AMT_GOODS_PRICE", "Price of goods financed", "Dictionary: 'For consumer loans it is the price of the goods for which the loan is given'.",
  "AMT_CREDIT", "Loan amount", "Dictionary: 'Credit amount of the loan'.",
  "ltv_x_pti", "Loan-to-value x payment-to-income", "ltv multiplied by pti (AMT_ANNUITY / capped AMT_INCOME_TOTAL).",
  "pti", "Payment-to-income", "AMT_ANNUITY / AMT_INCOME_TOTAL (income capped at the 99th percentile).",
  "CODE_GENDERM", "Gender: male", "1 if CODE_GENDER = M (reference F; the 4 'XNA' rows were folded into F).",
  "NAME_EDUCATION_TYPEHigher education", "Education: higher education", "1 if highest education = 'Higher education' (reference level: Academic degree).",
  "NAME_EDUCATION_TYPESecondary / secondary special", "Education: secondary", "1 if highest education = 'Secondary / secondary special'.",
  "NAME_EDUCATION_TYPEIncomplete higher", "Education: incomplete higher", "1 if highest education = 'Incomplete higher'.",
  "NAME_EDUCATION_TYPELower secondary", "Education: lower secondary", "1 if highest education = 'Lower secondary'.",
  "bureau_debt_to_credit", "Bureau debt / credit on open accounts", "Sum of current debt / sum of credit amount over the applicant's ACTIVE credit-bureau credits (median imputed if no bureau record).",
  "bureau_active_share", "Share of bureau credits still open", "Active bureau credits / all bureau credits (median imputed if no bureau record).",
  "bureau_active_credits", "Number of open bureau credits", "Count of credit-bureau credits with status Active (0 if no record).",
  "bureau_max_overdue_amount", "Largest overdue amount at bureau", "Maximum AMT_CREDIT_MAX_OVERDUE across the applicant's bureau credits.",
  "employed_share_of_life", "Share of life in current job", "years_employed / age_years (engineered; uses age).",
  "years_employed", "Years in current job", "-DAYS_EMPLOYED / 365.25; sentinel 365243 recoded to missing and median-imputed (see not_currently_employed).",
  "age_years", "Age", "-DAYS_BIRTH / 365.25.",
  "OWN_CAR_AGE", "Age of applicant's car", "Dictionary: 'Age of client's car' (median imputed when absent).",
  "FLAG_OWN_CARY", "Owns a car", "Dictionary: 'Flag if the client owns a car'.",
  "FLAG_DOCUMENT_3", "Provided document 3", "Dictionary: 'Did client provide document 3'. The document is not identified.",
  "NAME_INCOME_TYPEWorking", "Income type: working", "1 if NAME_INCOME_TYPE = 'Working'.",
  "years_since_id_publish", "Years since ID document changed", "-DAYS_ID_PUBLISH / 365.25: years since the applicant changed the identity document used to apply.",
  "NAME_FAMILY_STATUSMarried", "Family status: married", "1 if NAME_FAMILY_STATUS = 'Married'.",
  "DEF_30_CNT_SOCIAL_CIRCLE", "Defaults in social circle (30 DPD)", "Dictionary: 'How many observation of client's social surroundings defaulted on 30 DPD'.",
  "FLAG_WORK_PHONE", "Work phone flag", "Dictionary text says 'Did client provide home phone'; the label is ambiguous (duplicated with FLAG_PHONE).",
  "fields_missing", "Number of blank application fields", "Count of blank fields on the raw application (engineered)."
)
describe <- function(f) {
  d <- desc_map[match(f, desc_map$feature), ]
  tibble(feature = f, readable = coalesce(d$readable, f),
         definition = coalesce(d$definition, dict$Description[match(source_var[f], dict$Row)], "See data_preparation.R"))
}

# -----------------------------------------------------------------------------
# 3. Global importance and direction
# -----------------------------------------------------------------------------
direction_of <- function(f) {
  x <- X[, f]; v <- shap[, f]
  if (all(x %in% c(0, 1))) {
    d <- mean(v[x == 1]) - mean(v[x == 0])
    tibble(direction_stat = d, direction_type = "mean SHAP(1) - mean SHAP(0)",
           direction = case_when(d > 0.02 ~ "Having this attribute raises predicted risk",
                                 d < -0.02 ~ "Having this attribute lowers predicted risk",
                                 TRUE ~ "Negligible / mixed"))
  } else {
    r <- suppressWarnings(cor(x, v, method = "spearman"))
    tibble(direction_stat = r, direction_type = "Spearman(value, SHAP)",
           direction = case_when(r > 0.5 ~ "Higher values raise predicted risk",
                                 r < -0.5 ~ "Higher values lower predicted risk",
                                 TRUE ~ "Non-monotonic / interaction-dependent"))
  }
}
importance <- tibble(feature = colnames(shap), mean_abs_shap = colMeans(abs(shap)),
                     mean_shap = colMeans(shap), source_variable = source_var[colnames(shap)]) |>
  arrange(desc(mean_abs_shap)) |>
  mutate(rank = row_number(), share_of_total = mean_abs_shap / sum(mean_abs_shap))
n_used <- sum(importance$mean_abs_shap > 0)
top15 <- importance |> slice_head(n = 15) |>
  bind_cols(map_dfr(importance$feature[1:15], direction_of)) |>
  left_join(describe(importance$feature[1:15]), by = "feature") |>
  select(rank, feature, readable, definition, mean_abs_shap, share_of_total, direction, direction_stat, direction_type, source_variable)

# Variable- and family-level aggregation (SHAP is additive, so sums are valid).
shap_by_var <- shap %*% sapply(unique(source_var), function(v) as.numeric(source_var == v))
colnames(shap_by_var) <- unique(source_var)
family_of <- function(v) case_when(
  str_detect(v, "^EXT_SOURCE|^ext_") ~ "External scores (EXT_SOURCE family)",
  v %in% c("ltv", "credit_to_annuity", "AMT_ANNUITY", "AMT_CREDIT", "AMT_GOODS_PRICE", "ltv_x_pti", "pti", "pti_decile", "ltv_band", "credit_to_income", "NAME_CONTRACT_TYPE") ~ "Loan structure and affordability",
  str_detect(v, "^bureau_|has_bureau|thin_file") ~ "Credit bureau history",
  v %in% c("years_employed", "employed_share_of_life", "tenure_band", "not_currently_employed", "NAME_INCOME_TYPE", "ORGANIZATION_TYPE", "OCCUPATION_TYPE") ~ "Employment and income type",
  v %in% c("CODE_GENDER") ~ "Gender (protected)",
  v %in% c("age_years", "age_band") ~ "Age (protected; restricted use)",
  v %in% c("NAME_EDUCATION_TYPE") ~ "Education",
  v %in% c("NAME_FAMILY_STATUS", "CNT_CHILDREN", "CNT_FAM_MEMBERS") ~ "Family status (marital status protected)",
  TRUE ~ "Other application data")
var_importance <- tibble(source_variable = colnames(shap_by_var), mean_abs_shap = colMeans(abs(shap_by_var))) |>
  arrange(desc(mean_abs_shap)) |> mutate(rank = row_number(), family = family_of(source_variable))
family_importance <- tibble(family = family_of(colnames(shap_by_var)), idx = seq_len(ncol(shap_by_var))) |>
  group_by(family) |> summarise(idx = list(idx), .groups = "drop") |>
  mutate(mean_abs_shap = map_dbl(idx, ~ mean(abs(rowSums(shap_by_var[, .x, drop = FALSE]))))) |>
  select(-idx) |> arrange(desc(mean_abs_shap))

# -----------------------------------------------------------------------------
# 4. Protected characteristics
# -----------------------------------------------------------------------------
f_x <- rowSums(contrib)                     # log-odds
logodds_gender <- shap_by_var[, "CODE_GENDER"]
logodds_edu    <- shap_by_var[, "NAME_EDUCATION_TYPE"]
logodds_family <- shap_by_var[, "NAME_FAMILY_STATUS"]
logodds_age    <- shap_by_var[, "age_years"] + shap_by_var[, "age_band"]
# Probability-scale effect of removing one variable's contribution, holding the
# rest of that applicant's SHAP decomposition fixed (a descriptive transform).
pp_effect <- function(lo) plogis(f_x) - plogis(f_x - lo)
protected <- bind_rows(
  tibble(attribute = "CODE_GENDER", group = as.character(s$CODE_GENDER), lo = logodds_gender),
  tibble(attribute = "NAME_EDUCATION_TYPE", group = as.character(s$NAME_EDUCATION_TYPE), lo = logodds_edu),
  tibble(attribute = "NAME_FAMILY_STATUS", group = as.character(s$NAME_FAMILY_STATUS), lo = logodds_family),
  tibble(attribute = "Age (age_years + age_band)", group = as.character(cut(s$age_years, c(-Inf, 30, 40, 50, 62, Inf), right = FALSE,
                                                                             labels = c("< 30", "30-39", "40-49", "50-61", "62+ (elderly, Reg B)"))),
         lo = logodds_age)) |>
  mutate(pp = c(pp_effect(logodds_gender), pp_effect(logodds_edu), pp_effect(logodds_family), pp_effect(logodds_age))) |>
  group_by(attribute, group) |>
  summarise(n = n(), mean_logodds = mean(lo), mean_pp = mean(pp), min_pp = min(pp), max_pp = max(pp),
            share_raising_risk = mean(lo > 0), .groups = "drop")
protected_rank <- var_importance |>
  filter(source_variable %in% c("CODE_GENDER", "NAME_EDUCATION_TYPE", "NAME_FAMILY_STATUS", "age_years", "age_band",
                                "ext_mean_x_age", "employed_share_of_life", "NAME_INCOME_TYPE"))
elderly <- s$age_years >= 62
elderly_check <- tibble(
  check = c("Elderly (62+) applicants in sample",
            "Elderly with risk-raising direct age contribution (age_years + age_band > 0)",
            "Elderly with risk-raising age-derived contribution (+ ext_mean_x_age + employed_share_of_life > 0)"),
  value = c(sum(elderly), sum(logodds_age[elderly] > 0),
            sum((logodds_age + shap_by_var[, "ext_mean_x_age"] + shap_by_var[, "employed_share_of_life"])[elderly] > 0)))

# -----------------------------------------------------------------------------
# 5. Applicant-specific reasons
# -----------------------------------------------------------------------------
# Approximate decline set: Platt(raw) >= 0.25 using Step 3 coefficients. The
# calibrator was fitted for development-fold models, so applying it to the
# full-data model is an approximation used only to pick illustrative cases.
a <- calib$platt$coefficients[[1]]; b <- calib$platt$coefficients[[2]]
prob_cal <- plogis(a + b * qlogis(prob_direct))
would_decline <- prob_cal >= 0.25
top_reasons <- map_dfr(which(would_decline), function(i) {
  v <- shap_by_var[i, ]; v <- sort(v[v > 0], decreasing = TRUE)[1:4]
  tibble(applicant = i, reason_rank = 1:4, source_variable = names(v), logodds = unname(v))
}) |> filter(!is.na(source_variable))
reason_freq <- top_reasons |>
  count(source_variable, name = "times_in_top4") |>
  mutate(share_of_declined = times_in_top4 / sum(would_decline)) |>
  left_join(top_reasons |> filter(reason_rank == 1) |> count(source_variable, name = "times_rank1"), by = "source_variable") |>
  mutate(times_rank1 = replace_na(times_rank1, 0L), family = family_of(source_variable)) |>
  arrange(desc(times_in_top4))
sensitive_vars <- c("CODE_GENDER", "NAME_FAMILY_STATUS", "age_years", "age_band", "NAME_EDUCATION_TYPE")
unexplained_vars <- c("ext_source_mean", "ext_source_min", "ext_source_max", "EXT_SOURCE_1", "EXT_SOURCE_2", "EXT_SOURCE_3",
                      "EXT_SOURCE_1_missing", "EXT_SOURCE_3_missing", "ext_source_count", "ext_mean_x_age", "FLAG_DOCUMENT_3",
                      "DEF_30_CNT_SOCIAL_CIRCLE", "FLAG_WORK_PHONE")
decline_reason_flags <- top_reasons |> group_by(applicant) |>
  summarise(has_sensitive = any(source_variable %in% sensitive_vars),
            has_gender = any(source_variable == "CODE_GENDER"),
            top1_external = first(source_variable) %in% unexplained_vars,
            has_unexplained = any(source_variable %in% unexplained_vars), .groups = "drop") |>
  summarise(declined_in_sample = n(), share_with_sensitive_reason = mean(has_sensitive),
            share_with_gender_reason = mean(has_gender),
            share_top1_undocumented = mean(top1_external), share_with_undocumented = mean(has_unexplained))

# -----------------------------------------------------------------------------
# 6. Figures
# -----------------------------------------------------------------------------
theme_card <- theme_minimal(base_size = 11) +
  theme(panel.grid.minor = element_blank(), panel.grid.major = element_line(colour = "grey90"),
        plot.background = element_rect(fill = "#fcfcfb", colour = NA),
        text = element_text(colour = "#0b0b0b"), axis.text = element_text(colour = "#52514e"),
        plot.title.position = "plot")
lab_of <- setNames(paste0(describe(top15$feature)$readable, "  [", top15$feature, "]"), top15$feature)

# Beeswarm (manual quasi-random offsets; no extra packages).
bee <- map_dfr(top15$feature, function(f) {
  v <- shap[, f]; x <- X[, f]
  pr <- rank(x, ties.method = "average") / length(x)
  bin <- cut(v, breaks = 70, labels = FALSE)
  tibble(feature = f, shap = v, value_pct = pr, bin = bin) |>
    group_by(bin) |> mutate(k = row_number() - 1, off = ifelse(k %% 2 == 0, 1, -1) * ceiling(k / 2)) |>
    ungroup() |> mutate(off = off / max(1, max(abs(off))) * 0.38)
}) |> mutate(y = match(feature, rev(top15$feature)) + off)
g_bee <- ggplot(bee, aes(shap, y, colour = value_pct)) +
  geom_vline(xintercept = 0, colour = "grey60") +
  geom_point(size = 0.9, alpha = 0.85) +
  scale_y_continuous(breaks = seq_along(top15$feature), labels = rev(lab_of[top15$feature]), expand = c(0.02, 0)) +
  scale_colour_gradient2(low = "#2a78d6", mid = "#b5b3ad", high = "#eb6834", midpoint = 0.5,
                         breaks = c(0.05, 0.95), labels = c("Low", "High"), name = "Feature value\n(rank within sample)") +
  labs(x = "SHAP value (log-odds of payment difficulty; right = higher predicted risk)", y = NULL,
       title = "SHAP summary: top 15 encoded features (final model, 1,000 labeled applicants)",
       subtitle = "In-sample: the model was trained on these applicants. Binary features show only two colours.") +
  theme_card + theme(legend.position = "right")
ggsave(file.path(out_dir, "step6_shap_beeswarm.png"), g_bee, width = 11, height = 7, dpi = 150)

g_bar <- top15 |>
  mutate(lbl = factor(lab_of[feature], levels = rev(lab_of[feature]))) |>
  ggplot(aes(mean_abs_shap, lbl)) +
  geom_col(fill = "#2a78d6", width = 0.6) +
  geom_text(aes(label = sprintf("%.3f", mean_abs_shap)), hjust = -0.15, size = 3.1, colour = "#0b0b0b") +
  scale_x_continuous(expand = expansion(mult = c(0, 0.12))) +
  labs(x = "Mean |SHAP| (log-odds)", y = NULL,
       title = "Global importance: mean absolute SHAP, top 15 encoded features",
       subtitle = sprintf("Final model, 1,000 labeled applicants (in-sample).\n%d of 300 encoded features have any effect.", n_used)) +
  theme_card + theme(panel.grid.major.y = element_blank())
ggsave(file.path(out_dir, "step6_shap_importance_top15.png"), g_bar, width = 10, height = 6, dpi = 150)

value_label <- function(i, f) {
  x <- X[i, f]
  if (all(X[, f] %in% c(0, 1))) return(if (x == 1) "yes" else "no")
  if (abs(x) >= 1000) scales::comma(x, accuracy = 1) else format(signif(x, 3))
}
waterfall <- function(i, title, file) {
  v <- shap[i, ]; o <- order(abs(v), decreasing = TRUE)
  top <- o[1:10]; rest <- sum(v[-top])
  steps <- tibble(label = c(paste0(describe(names(v)[top])$readable, " = ", map_chr(names(v)[top], ~ value_label(i, .x))),
                            sprintf("Other %d features", sum(v[-top] != 0))),
                  value = c(unname(v[top]), rest)) |>
    mutate(end = base_logodds + cumsum(value), start = lag(end, default = base_logodds),
           dir = if_else(value > 0, "Raises predicted risk", "Lowers predicted risk"),
           pos = rev(seq_len(n())))
  fx <- base_logodds + sum(v)
  ggplot(steps) +
    geom_vline(xintercept = base_logodds, colour = "grey55", linetype = "dashed") +
    geom_vline(xintercept = fx, colour = "#0b0b0b", linetype = "dotted") +
    geom_rect(aes(xmin = pmin(start, end), xmax = pmax(start, end), ymin = pos - 0.36, ymax = pos + 0.36, fill = dir)) +
    geom_text(aes(x = pmax(start, end), y = pos, label = sprintf("%+.3f", value)), hjust = -0.15, size = 3, colour = "#0b0b0b") +
    scale_y_continuous(breaks = steps$pos, labels = steps$label) +
    scale_x_continuous(expand = expansion(mult = c(0.05, 0.12))) +
    scale_fill_manual(values = c(`Raises predicted risk` = "#eb6834", `Lowers predicted risk` = "#2a78d6"), name = NULL) +
    labs(x = "Log-odds of payment difficulty", y = NULL, title = title,
         subtitle = sprintf("Base value %.3f log-odds (p = %.3f)  ->  this applicant %.3f log-odds (raw p = %.3f; Platt-scaled p ~ %.3f).\nActual TARGET = %d. In-sample: the model was trained on this applicant. Bars are log-odds, not probability points.",
                            base_logodds, plogis(base_logodds), fx, plogis(fx), prob_cal[i], s$TARGET[i])) +
    theme_card + theme(legend.position = "top", panel.grid.major.y = element_blank())
  ggsave(file.path(out_dir, file), width = 11, height = 5.6, dpi = 150)
  steps |> mutate(applicant_SK_ID_CURR = s$SK_ID_CURR[i], raw_p = plogis(fx), platt_p = prob_cal[i], TARGET = s$TARGET[i])
}
i_high <- which.max(prob_direct); i_low <- which.min(prob_direct)
wf_high <- waterfall(i_high, "Waterfall: highest predicted risk in the sample", "step6_waterfall_high_risk.png")
wf_low  <- waterfall(i_low,  "Waterfall: lowest predicted risk in the sample", "step6_waterfall_low_risk.png")

# -----------------------------------------------------------------------------
# 7. Adverse-action mapping (judgement documented in step6_findings.md)
# -----------------------------------------------------------------------------
adverse_action <- tribble(
  ~model_feature, ~verified_definition, ~risk_increasing_condition, ~candidate_explanation, ~supported_for_adverse_action, ~limitations_or_concerns,
  "ext_source_mean / ext_source_min / ext_source_max / EXT_SOURCE_1-3 (+ missing flags, ext_mean_x_age)",
  "Summaries of three 'normalized score[s] from external data source'; provider and meaning undocumented.",
  "Low average or minimum external score; external score 1 missing.",
  "None can be stated accurately without vendor documentation (e.g., NOT 'poor credit score' or 'insufficient credit history').",
  "No - not until the source, inputs and meaning of each score are documented",
  "Largest driver of the model. CFPB Circ. 2022-03/2023-03: reasons must be specific and accurate; an unexplained third-party score cannot be translated by guesswork. ext_mean_x_age also embeds age.",
  "ltv", "AMT_CREDIT / AMT_GOODS_PRICE.",
  "Loan amount high relative to the price of the goods (in the sample, SHAP turns positive above ~1.16, i.e. fees/insurance financed).",
  "Amount financed is high relative to the value of the goods purchased.",
  "Yes, with validation",
  "Mostly monotonic in this sample (Spearman 0.90); cite only when this applicant's ltv contribution is materially positive.",
  "credit_to_annuity", "AMT_CREDIT / AMT_ANNUITY (approximate number of payments).",
  "Loan/payment ratio in the risk-raising range for this applicant (relationship is non-monotonic).",
  "Requested loan term / repayment schedule.",
  "Partly - needs validation; it is a proxy, not the contractual term",
  "Proxy for term; interaction-dependent. Explanation must be checked against the actual product terms.",
  "AMT_ANNUITY / AMT_GOODS_PRICE / AMT_CREDIT", "Payment amount; price of goods; loan amount (data dictionary).",
  "Larger payment or loan amount, given the other features.",
  "Amount of credit or payment requested.",
  "Yes, with validation",
  "Effects depend on other loan features; pair with affordability where relevant.",
  "bureau_debt_to_credit", "Current debt / credit amount on active bureau credits.",
  "High share of open bureau credit still owed.",
  "Outstanding balances are high relative to credit amounts on your existing accounts.",
  "Yes, with validation",
  "Imputed with the median when no bureau record - must not be cited for applicants without bureau data.",
  "bureau_active_share / bureau_active_credits", "Share and count of bureau credits still active.",
  "Many or a high share of open credit accounts.",
  "Number of open credit accounts / proportion of accounts still open.",
  "Yes, with validation",
  "Imputed/zero when no bureau record; not applicable then.",
  "bureau_max_overdue_amount", "Maximum overdue amount ever reported on a bureau credit.",
  "Large past overdue amount.",
  "Delinquency reported on past or present credit obligations.",
  "Yes",
  "Standard, well-understood reason; verify data accuracy (FCRA-style disputes in a US context).",
  "employed_share_of_life / years_employed", "Years in current job; that tenure divided by age.",
  "Short time in current job (and, for the ratio, relative to age).",
  "Length of employment.",
  "years_employed: Yes. employed_share_of_life: needs legal review",
  "employed_share_of_life uses age in its denominator, so it is partly an age variable (Reg B 1002.6(b)(2)).",
  "OWN_CAR_AGE / FLAG_OWN_CARY", "Age of client's car; car ownership flag.",
  "No car, or an older car (check per applicant).",
  "Assets / collateral information.",
  "Partly - needs business justification",
  "Proxy for wealth; possible disparate impact; ownership rarely a direct repayment factor for unsecured loans.",
  "FLAG_DOCUMENT_3", "'Did client provide document 3' - document not identified.",
  "Document 3 provided or not (direction per SHAP).",
  "None until the document is identified.",
  "No",
  "Unknown meaning; cannot produce a specific, accurate reason.",
  "years_since_id_publish", "Years since the applicant changed the ID document used to apply.",
  "Recently changed identity document.",
  "Recent change of identification document.",
  "Questionable - needs legal review",
  "Not intuitively related to repayment; may proxy for life events or national origin/immigration status.",
  "DEF_30_CNT_SOCIAL_CIRCLE", "Defaults (30 DPD) among the applicant's 'social surroundings'.",
  "More defaults among people connected to the applicant.",
  "None appropriate - reflects other people's behavior.",
  "No",
  "Data about third parties; CFPB Circ. 2023-03 highlights data not typically in a credit file; high fair-lending and reputational risk.",
  "CODE_GENDER (CODE_GENDERM)", "Gender of the client (M vs F).",
  "Being male raises predicted risk in this model.",
  "Must never be given - sex is a prohibited basis.",
  "No - prohibited basis",
  "12 CFR 1002.6(b)(9): a creditor shall not consider sex in any aspect of a credit transaction. Must be removed before any US-style use.",
  "NAME_EDUCATION_TYPE", "Highest education level.",
  "Secondary / lower education (relative to higher education).",
  "Should not be used as an adverse-action reason without legal review.",
  "No - not without legal and business justification",
  "Not a listed prohibited basis, but strongly correlated with protected characteristics; disparate-impact risk.",
  "NAME_FAMILY_STATUS", "Family status of the client.",
  "Marital status category with risk-raising SHAP.",
  "Must never be given - marital status is a prohibited basis.",
  "No - prohibited basis",
  "12 CFR 1002.2(z) and 1002.6(b)(8): married and unmarried applicants must be evaluated by the same standards.",
  "age_years / age_band", "Applicant age in years / age band.",
  "Younger age raises predicted risk.",
  "Only if the system qualifies as empirically derived and sound and elderly applicants are never disfavored; otherwise none.",
  "No - restricted (needs legal review)",
  "12 CFR 1002.6(b)(2): age may be used only in an empirically derived, demonstrably and statistically sound system, and elderly (62+) applicants must not receive a negative value. Checked in step6_elderly_check.csv."
)

# -----------------------------------------------------------------------------
# 8. Save
# -----------------------------------------------------------------------------
saveRDS(list(shap = shap, base_logodds = base_logodds, X = X, SK_ID_CURR = s$SK_ID_CURR, TARGET = s$TARGET,
             prob_raw = prob_direct, prob_platt_approx = prob_cal, source_var = source_var, seed = 20261025),
        file.path(out_dir, "step6_shap_values.rds"))
write_csv(checks, file.path(out_dir, "step6_checks.csv"))
write_csv(top15, file.path(out_dir, "step6_feature_importance_top15.csv"))
write_csv(importance, file.path(out_dir, "step6_feature_importance_all_encoded.csv"))
write_csv(var_importance, file.path(out_dir, "step6_importance_by_source_variable.csv"))
write_csv(family_importance, file.path(out_dir, "step6_importance_by_family.csv"))
write_csv(protected, file.path(out_dir, "step6_protected_attribute_effects.csv"))
write_csv(protected_rank, file.path(out_dir, "step6_protected_attribute_rank.csv"))
write_csv(elderly_check, file.path(out_dir, "step6_elderly_check.csv"))
write_csv(reason_freq, file.path(out_dir, "step6_applicant_reason_frequency.csv"))
write_csv(decline_reason_flags, file.path(out_dir, "step6_decline_reason_flags.csv"))
write_csv(bind_rows(mutate(wf_high, case = "high risk"), mutate(wf_low, case = "low risk")),
          file.path(out_dir, "step6_waterfall_cases.csv"))
write_csv(adverse_action, file.path(out_dir, "step6_adverse_action_mapping.csv"))

# -----------------------------------------------------------------------------
# 9. Console report
# -----------------------------------------------------------------------------
options(width = 220, pillar.sigfig = 4)
print(checks)
cat("\nEncoded features with any effect:", n_used, "of 300\n")
cat("\n== Top 15 ==\n"); print(as.data.frame(select(top15, rank, feature, readable, mean_abs_shap, share_of_total, direction, direction_stat)))
cat("\n== By source variable (top 20) ==\n"); print(as.data.frame(head(var_importance, 20)))
cat("\n== By family ==\n"); print(as.data.frame(family_importance))
cat("\n== Protected ranks ==\n"); print(as.data.frame(protected_rank))
cat("\n== Protected effects ==\n"); print(as.data.frame(protected), digits = 3)
cat("\n== Elderly check ==\n"); print(elderly_check)
cat("\n== Would-decline (approx) in sample:", sum(would_decline), "\n"); print(as.data.frame(head(reason_freq, 15)))
print(decline_reason_flags)
cat("\n== Waterfall high ==\n"); print(as.data.frame(select(wf_high, label, value, applicant_SK_ID_CURR, raw_p, platt_p, TARGET)))
cat("\n== Waterfall low ==\n"); print(as.data.frame(select(wf_low, label, value, applicant_SK_ID_CURR, raw_p, platt_p, TARGET)))
# Direction details for non-monotonic top features
for (f in c("ltv", "credit_to_annuity", "AMT_ANNUITY", "AMT_GOODS_PRICE", "OWN_CAR_AGE", "years_since_id_publish", "age_years", "FLAG_DOCUMENT_3")) {
  if (f %in% colnames(X)) {
    q <- cut(X[, f], unique(quantile(X[, f], seq(0, 1, 0.2))), include.lowest = TRUE)
    cat("\n", f, "\n"); print(tapply(shap[, f], q, mean))
  }
}
