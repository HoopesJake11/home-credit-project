# Step 4 of the model card: financial decision-threshold analysis on the
# development out-of-fold (OOF) predictions from Step 3.
#
# * Uses only models/model_card/step3_oof_predictions.rds (246,009 development
#   applicants). The 61,502-row holdout is not read. No model is trained.
# * Rule: approve when the predicted payment-difficulty probability is below the
#   threshold t; otherwise decline / refer. TARGET = 1 means payment difficulty
#   (late on an early installment), NOT a confirmed write-off; the Step 2 loss
#   conversion c turns it into a scenario-level money proxy.
# * Profit per approved applicant (per unit of principal):
#     TARGET = 0:  +G          TARGET = 1:  -L = -c * EAD * LGD
#   Declined applicants contribute 0. Losses enter only through L.
#
#   "C:/Program Files/R/R-4.5.2/bin/Rscript.exe" analysis/model_card/step4_threshold_optimization.R

suppressPackageStartupMessages(library(tidyverse))
out_dir   <- "models/model_card"
principal <- 8437  # TransUnion Q2 2026 average unsecured personal-loan balance; $ illustration only

# -----------------------------------------------------------------------------
# 1. Rebuild and verify the Step 2 assumptions from their primitives
# -----------------------------------------------------------------------------
amortization <- function(apr, n) {
  r <- apr / 12
  pmt <- r / (1 - (1 + r)^-n)
  bal <- numeric(n + 1); bal[1] <- 1
  for (k in 1:n) bal[k + 1] <- bal[k] * (1 + r) - pmt
  list(payment = pmt, balance = bal, principal_years = sum(bal[1:n]) / 12)
}
am24 <- amortization(0.40, 24)

scenarios <- tribble(
  ~scenario,      ~margin_source,                                  ~m,                       ~k_paid, ~lgd,               ~c,
  "Conservative", "FDIC consumer lenders: NIM + nonint inc - exp", 0.0473 + 0.0141 - 0.0307, 0,       0.96,               1.00,
  "Base",         "Home Credit FY2018: NIM x (1 - CIR 42.2%)",     0.158 * (1 - 0.422),      3,       (0.45 + 0.96) / 2,  0.50,
  "Optimistic",   "Home Credit Q1 2019: NIM x (1 - CIR 39.4%)",    0.158 * (1 - 0.394),      6,       0.45,               0.25
) |>
  mutate(T_principal_years = am24$principal_years,
         G   = m * T_principal_years,
         EAD = am24$balance[k_paid + 1],
         loss_given_true_default = EAD * lgd,
         L   = c * loss_given_true_default,
         p_star = G / (G + L),
         G_usd = G * principal, L_usd = L * principal)

step2_reported <- tibble(scenario = c("Conservative", "Base", "Optimistic"),
                         G_reported = c(0.036, 0.107, 0.112),
                         EAD_reported = c(1.000, 0.914, 0.818),
                         L_reported = c(0.960, 0.322, 0.092),
                         p_star_reported = c(0.036, 0.249, 0.549))
assumption_check <- scenarios |>
  left_join(step2_reported, by = "scenario") |>
  mutate(G_matches = abs(G - G_reported) < 0.0005,
         EAD_matches = abs(EAD - EAD_reported) < 0.0005,
         L_matches = abs(L - L_reported) < 0.0005,
         p_star_matches = abs(p_star - p_star_reported) < 0.0005)
stopifnot(all(assumption_check$p_star_matches))

# Term sensitivity: the median credit/annuity ratio in application_train
# (20.7, Step 2) suggests terms longer than 24 months for current loans.
term_sensitivity <- map_dfr(c(12, 24, 36, 48), function(n) {
  am <- amortization(0.40, n)
  b <- filter(scenarios, scenario == "Base")
  G <- b$m * am$principal_years
  L <- b$c * am$balance[b$k_paid + 1] * b$lgd
  tibble(term_months = n, credit_to_payment = 1 / am$payment,
         principal_years = am$principal_years, G = G, L = L, p_star = G / (G + L))
})

# -----------------------------------------------------------------------------
# 2. OOF predictions
# -----------------------------------------------------------------------------
oof <- readRDS(file.path(out_dir, "step3_oof_predictions.rds"))
stopifnot(nrow(oof) == 246009, !anyDuplicated(oof$SK_ID_CURR),
          all(c("prob_raw", "prob_platt_cf", "prob_isotonic_cf") %in% names(oof)))
y <- oof$TARGET
n <- length(y)
score_cols <- c(Platt = "prob_platt_cf", Raw = "prob_raw", Isotonic = "prob_isotonic_cf")

# -----------------------------------------------------------------------------
# 3. Threshold metrics
# -----------------------------------------------------------------------------
threshold_metrics <- function(p, y, t) {
  approve <- p < t
  tn <- sum(approve & y == 0); fn <- sum(approve & y == 1)   # approved
  tp <- sum(!approve & y == 1); fp <- sum(!approve & y == 0) # declined
  tibble(threshold = t, applicants = length(y), approved = tn + fn, declined = tp + fp,
         approval_rate = (tn + fn) / length(y),
         TP_declined_target1 = tp, FP_declined_target0 = fp,
         TN_approved_target0 = tn, FN_approved_target1 = fn,
         precision = if (tp + fp > 0) tp / (tp + fp) else NA_real_,
         recall = tp / (tp + fn), specificity = tn / (tn + fp), fpr = fp / (tn + fp),
         target_rate_approved = if (tn + fn > 0) fn / (tn + fn) else NA_real_,
         mean_pred_approved = if (tn + fn > 0) mean(p[approve]) else NA_real_)
}
add_profit <- function(tbl, scen) {
  tbl |>
    crossing(select(scen, scenario, G, L)) |>
    mutate(profit_total = TN_approved_target0 * G - FN_approved_target1 * L,
           profit_per_applicant = profit_total / applicants,
           profit_per_approved = if_else(approved > 0, profit_total / approved, NA_real_),
           approve_all_total = sum(y == 0) * G - sum(y == 1) * L,
           improvement_total = profit_total - approve_all_total,
           improvement_per_applicant = improvement_total / applicants,
           profit_per_applicant_usd = profit_per_applicant * principal,
           profit_total_usd = profit_total * principal,
           improvement_total_usd = improvement_total * principal)
}

report_thresholds <- sort(unique(round(c(seq(0.05, 0.60, by = 0.05), seq(0.20, 0.30, by = 0.01),
                                         scenarios$p_star), 4)))
threshold_table <- imap_dfr(score_cols, function(col, nm) {
  map_dfr(report_thresholds, ~ threshold_metrics(oof[[col]], y, .x)) |> mutate(score = nm, .before = 1)
}) |> add_profit(scenarios) |>
  mutate(is_p_star = map2_lgl(threshold, scenario, ~ abs(.x - round(scenarios$p_star[scenarios$scenario == .y], 4)) < 1e-9))

# Fine grid for curves and empirical optima.
fine_grid <- seq(0.01, 0.80, by = 0.0025)
fine_grid <- sort(unique(c(fine_grid, round(scenarios$p_star, 4))))
curve_fast <- function(p, y, grid) {
  o <- order(p); ps <- p[o]; ys <- y[o]
  idx <- findInterval(grid, ps, left.open = TRUE)  # count of p < t
  cum1 <- c(0, cumsum(ys))[idx + 1]
  tibble(threshold = grid, approved = idx, approved_target1 = cum1, approved_target0 = idx - cum1)
}
curves <- imap_dfr(score_cols, function(col, nm) curve_fast(oof[[col]], y, fine_grid) |> mutate(score = nm)) |>
  crossing(select(scenarios, scenario, G, L)) |>
  mutate(profit_per_applicant = (approved_target0 * G - approved_target1 * L) / n,
         approval_rate = approved / n,
         recall = (sum(y) - approved_target1) / sum(y),
         precision = (sum(y) - approved_target1) / pmax(n - approved, 1),
         target_rate_approved = approved_target1 / pmax(approved, 1))

empirical_optima <- curves |>
  group_by(score, scenario) |>
  slice_max(profit_per_applicant, n = 1, with_ties = FALSE) |>
  ungroup() |>
  left_join(select(scenarios, scenario, p_star), by = "scenario") |>
  mutate(approve_all_per_applicant = (sum(y == 0) * G - sum(y == 1) * L) / n,
         improvement_per_applicant = profit_per_applicant - approve_all_per_applicant) |>
  select(score, scenario, p_star, empirical_threshold = threshold, approval_rate,
         recall, precision, target_rate_approved, profit_per_applicant,
         approve_all_per_applicant, improvement_per_applicant)

# Profit at the theoretical p* vs at the empirical optimum (same score).
p_star_vs_empirical <- curves |>
  inner_join(select(scenarios, scenario, p_star), by = "scenario") |>
  filter(abs(threshold - round(p_star, 4)) < 1e-9) |>
  select(score, scenario, profit_at_p_star = profit_per_applicant, approval_at_p_star = approval_rate) |>
  right_join(empirical_optima, by = c("score", "scenario")) |>
  mutate(profit_gap_per_applicant = profit_per_applicant - profit_at_p_star,
         profit_gap_share_of_improvement = profit_gap_per_applicant / improvement_per_applicant)

# Model-implied (expected) profit using calibrated Platt probabilities vs realized.
expected_vs_realized <- map_dfr(c(0.10, 0.20, 0.2493, 0.30, 0.40), function(t) {
  a <- oof$prob_platt_cf < t
  scenarios |> transmute(scenario, threshold = t,
                         realized_per_applicant = (sum(a & y == 0) * G - sum(a & y == 1) * L) / n,
                         expected_per_applicant = (sum((1 - oof$prob_platt_cf[a])) * G - sum(oof$prob_platt_cf[a]) * L) / n)
})

# -----------------------------------------------------------------------------
# 4. Applicant-level bootstrap (Platt score)
# -----------------------------------------------------------------------------
B <- 1000
set.seed(44)
p <- oof$prob_platt_cf
o <- order(p); ps <- p[o]; ys <- y[o]
idx <- findInterval(fine_grid, ps, left.open = TRUE)
base <- filter(scenarios, scenario == "Base")
rec_candidates <- round(c(base$p_star), 4)
boot <- vector("list", B)
boot_curve_base <- matrix(NA_real_, B, length(fine_grid))
for (b in 1:B) {
  w <- tabulate(sample.int(n, n, replace = TRUE), n)[o]
  cw <- c(0, cumsum(w)); cw1 <- c(0, cumsum(w * ys))
  appr <- cw[idx + 1]; appr1 <- cw1[idx + 1]; appr0 <- appr - appr1
  tot1 <- sum(w * ys)
  boot[[b]] <- scenarios |> select(scenario, G, L, p_star) |>
    pmap_dfr(function(scenario, G, L, p_star) {
      prof <- (appr0 * G - appr1 * L) / n
      j <- which.max(prof); js <- which(abs(fine_grid - round(p_star, 4)) < 1e-9)
      all_prof <- ((n - tot1) * G - tot1 * L) / n
      tibble(b = b, scenario = scenario,
             opt_threshold = fine_grid[j], opt_profit = prof[j],
             opt_improvement = prof[j] - all_prof,
             pstar_profit = prof[js], pstar_improvement = prof[js] - all_prof,
             pstar_approval = appr[js] / n,
             pstar_recall = (tot1 - appr1[js]) / tot1,
             pstar_precision = (tot1 - appr1[js]) / (n - appr[js]),
             pstar_target_rate_approved = appr1[js] / appr[js])
    })
  boot_curve_base[b, ] <- (appr0 * base$G - appr1 * base$L) / n
}
boot <- bind_rows(boot)
q <- function(x) quantile(x, c(0.025, 0.5, 0.975), names = FALSE)
bootstrap_summary <- boot |>
  pivot_longer(-c(b, scenario), names_to = "metric") |>
  group_by(scenario, metric) |>
  summarise(lo95 = q(value)[1], median = q(value)[2], hi95 = q(value)[3],
            share_positive = mean(value > 0), .groups = "drop")
boot_band <- tibble(threshold = fine_grid,
                    lo = apply(boot_curve_base, 2, quantile, 0.025),
                    hi = apply(boot_curve_base, 2, quantile, 0.975))

# Sensitivity grid over the two least-supported inputs (base G and EAD).
sens_grid <- crossing(c = c(0.25, 0.5, 0.75, 1.0), lgd = c(0.45, 0.60, 0.705, 0.80, 0.96)) |>
  mutate(G = base$G, L = c * base$EAD * lgd, p_star = G / (G + L))
platt_curve <- curve_fast(oof$prob_platt_cf, y, fine_grid)
sens_grid <- sens_grid |>
  mutate(res = pmap(list(G, L), function(G, L) {
    prof <- (platt_curve$approved_target0 * G - platt_curve$approved_target1 * L) / n
    j <- which.max(prof)
    tibble(empirical_threshold = fine_grid[j], approval_rate_at_opt = platt_curve$approved[j] / n,
           improvement_per_applicant = prof[j] - ((sum(y == 0)) * G - sum(y == 1) * L) / n)
  })) |> unnest(res)

# -----------------------------------------------------------------------------
# 5. Figures (palette validated with the dataviz validator: categorical slots
#    1-3; aqua is below 3:1 contrast, so lines are also direct-labelled and
#    distinguished by linetype)
# -----------------------------------------------------------------------------
pal <- c(Conservative = "#2a78d6", Base = "#eb6834", Optimistic = "#1baf7a")
ltys <- c(Conservative = "solid", Base = "solid", Optimistic = "longdash")
theme_card <- theme_minimal(base_size = 11) +
  theme(panel.grid.minor = element_blank(), panel.grid.major = element_line(colour = "grey90"),
        plot.background = element_rect(fill = "#fcfcfb", colour = NA),
        text = element_text(colour = "#0b0b0b"), axis.text = element_text(colour = "#52514e"),
        legend.position = "top")

platt_curves <- filter(curves, score == "Platt") |>
  mutate(scenario = factor(scenario, names(pal)))
opt_pts <- filter(empirical_optima, score == "Platt") |>
  mutate(scenario = factor(scenario, names(pal)))
end_lbl <- platt_curves |> group_by(scenario) |> slice_max(threshold, n = 1)

g1 <- ggplot(platt_curves, aes(threshold, profit_per_applicant * principal, colour = scenario, linetype = scenario)) +
  geom_hline(yintercept = 0, colour = "grey60") +
  geom_ribbon(data = boot_band, aes(x = threshold, ymin = lo * principal, ymax = hi * principal),
              inherit.aes = FALSE, fill = pal["Base"], alpha = 0.18) +
  geom_line(linewidth = 0.8) +
  geom_vline(data = scenarios |> mutate(scenario = factor(scenario, names(pal))),
             aes(xintercept = p_star, colour = scenario), linetype = "dotted", linewidth = 0.6, show.legend = FALSE) +
  geom_point(data = opt_pts, aes(empirical_threshold, profit_per_applicant * principal), size = 2.6, show.legend = FALSE) +
  geom_text(data = end_lbl, aes(label = scenario), hjust = -0.1, size = 3.4, colour = "#0b0b0b", show.legend = FALSE) +
  scale_colour_manual(values = pal) + scale_linetype_manual(values = ltys) +
  scale_x_continuous(limits = c(0, 0.88), breaks = seq(0, 0.8, 0.1)) +
  scale_y_continuous(labels = scales::dollar) +
  labs(x = "Threshold on Platt-calibrated probability (approve if below)",
       y = "Expected net profit per applicant (USD, P = $8,437)",
       colour = NULL, linetype = NULL,
       title = "Expected profit per applicant vs threshold (development OOF)",
       subtitle = "Dotted lines: theoretical break-even p*. Dots: empirical optimum. Base-case bootstrap band is too narrow to see here (see zoom chart).") +
  theme_card
ggsave(file.path(out_dir, "step4_profit_vs_threshold.png"), g1, width = 9, height = 5.2, dpi = 150)

rates <- filter(curves, score == "Platt", scenario == "Base") |>
  select(threshold, `Approval rate` = approval_rate, `TARGET = 1 rate among approved` = target_rate_approved,
         `Recall (TARGET = 1 declined)` = recall, `Precision (declined that are TARGET = 1)` = precision) |>
  pivot_longer(-threshold) |>
  mutate(panel = if_else(name %in% c("Approval rate", "TARGET = 1 rate among approved"),
                         "Approval and portfolio quality", "Precision and recall"))
# Two series per panel; each panel is direct-labelled (no shared legend), so
# the same two hues can be reused without implying identity across panels.
rates <- filter(rates, threshold >= 0.05, threshold <= 0.60) |>
  mutate(slot = if_else(name %in% c("Approval rate", "Recall (TARGET = 1 declined)"), "a", "b"))
label_at <- c(`Approval rate` = 0.30, `TARGET = 1 rate among approved` = 0.42,
              `Recall (TARGET = 1 declined)` = 0.13, `Precision (declined that are TARGET = 1)` = 0.40)
rate_lbl <- rates |> group_by(name) |>
  slice_min(abs(threshold - label_at[first(name)]), n = 1, with_ties = FALSE) |> ungroup()
g2 <- ggplot(rates, aes(threshold, value, colour = slot, group = name)) +
  geom_vline(xintercept = base$p_star, linetype = "dotted", colour = "grey40") +
  geom_line(linewidth = 0.8) +
  geom_label(data = rate_lbl, aes(label = name), colour = "#0b0b0b", fill = "#fcfcfb",
             label.size = 0, size = 3.1, vjust = -0.4) +
  facet_wrap(~ panel, scales = "free_y") +
  scale_colour_manual(values = c(a = "#2a78d6", b = "#eb6834"), guide = "none") +
  scale_y_continuous(labels = scales::percent) +
  labs(x = "Threshold on Platt-calibrated probability (0.05 to 0.60)", y = NULL,
       title = "Approval rate, portfolio quality, precision and recall vs threshold",
       subtitle = "Positive class = TARGET = 1 (payment difficulty), predicted when probability >= threshold. Dotted: base p* = 0.249.") +
  theme_card
ggsave(file.path(out_dir, "step4_rates_vs_threshold.png"), g2, width = 10, height = 4.8, dpi = 150)

g3 <- ggplot(sens_grid, aes(factor(lgd, labels = scales::percent(sort(unique(lgd)), 0.1)),
                            factor(c, labels = scales::percent(sort(unique(c)))), fill = empirical_threshold)) +
  geom_tile(colour = "#fcfcfb", linewidth = 1) +
  geom_text(aes(label = sprintf("t* %.3f\np* %.3f\napprove %.0f%%", empirical_threshold, p_star, 100 * approval_rate_at_opt)),
            size = 3, colour = "#0b0b0b") +
  scale_fill_gradient(low = "#cde2fb", high = "#5598e7", name = "Empirical\noptimum") +
  labs(x = "Loss given default (LGD)", y = "Loss conversion c = P(charge-off | TARGET = 1)",
       title = "Scenario sensitivity: optimal threshold by c and LGD (base margin and EAD)",
       subtitle = "t* = empirical profit-maximizing threshold (Platt OOF); p* = theoretical break-even") +
  theme_card + theme(panel.grid = element_blank())
ggsave(file.path(out_dir, "step4_sensitivity_heatmap.png"), g3, width = 8.5, height = 5.5, dpi = 150)

# Zoom: base-case gain over approve-everyone, with the bootstrap band.
approve_all_base <- ((n - sum(y)) * base$G - sum(y) * base$L) / n
zoom <- filter(curves, score == "Platt", scenario == "Base") |>
  select(threshold, profit_per_applicant) |>
  left_join(boot_band, by = "threshold") |>
  mutate(across(c(profit_per_applicant, lo, hi), ~ (.x - approve_all_base) * principal)) |>
  filter(threshold >= 0.10, threshold <= 0.50)
opt_base <- filter(empirical_optima, score == "Platt", scenario == "Base")
g1b <- ggplot(zoom, aes(threshold, profit_per_applicant)) +
  geom_hline(yintercept = 0, colour = "grey60") +
  geom_ribbon(aes(ymin = lo, ymax = hi), fill = pal["Base"], alpha = 0.2) +
  geom_line(colour = pal["Base"], linewidth = 0.9) +
  geom_vline(xintercept = base$p_star, linetype = "dotted", colour = "grey30") +
  geom_point(data = opt_base, aes(empirical_threshold, improvement_per_applicant * principal),
             colour = pal["Base"], size = 2.6) +
  annotate("text", x = base$p_star, y = max(zoom$hi) * 1.04, hjust = -0.05, size = 3.2,
           label = sprintf("p* = %.3f", base$p_star), colour = "#0b0b0b") +
  scale_y_continuous(labels = scales::dollar) +
  labs(x = "Threshold on Platt-calibrated probability",
       y = "Gain vs approve-everyone, USD per applicant",
       title = "Base case: profit gain over approving everyone",
       subtitle = "Band: 95% applicant-level bootstrap interval (B = 1,000). Dot: empirical optimum. Only sampling uncertainty is shown.") +
  theme_card
ggsave(file.path(out_dir, "step4_base_gain_zoom.png"), g1b, width = 8.5, height = 4.8, dpi = 150)

score_pal <- c(Platt = "#2a78d6", Raw = "#eb6834", Isotonic = "#1baf7a")
g4 <- filter(curves, scenario == "Base") |>
  mutate(score = factor(score, names(score_pal))) |>
  ggplot(aes(threshold, profit_per_applicant * principal, colour = score, linetype = score)) +
  geom_hline(yintercept = 0, colour = "grey60") +
  geom_vline(xintercept = base$p_star, linetype = "dotted", colour = "grey40") +
  geom_line(linewidth = 0.8) +
  scale_colour_manual(values = score_pal) +
  scale_linetype_manual(values = c(Platt = "solid", Raw = "longdash", Isotonic = "dotdash")) +
  scale_y_continuous(labels = scales::dollar) +
  coord_cartesian(xlim = c(0.05, 0.6)) +
  labs(x = "Threshold on the named probability scale", y = "Profit per applicant (USD), base case",
       colour = NULL, linetype = NULL,
       title = "Base-case profit vs threshold: Platt, raw and isotonic scores") +
  theme_card
ggsave(file.path(out_dir, "step4_score_type_sensitivity.png"), g4, width = 8.5, height = 4.8, dpi = 150)

# -----------------------------------------------------------------------------
# 6. Save tables
# -----------------------------------------------------------------------------
write_csv(assumption_check, file.path(out_dir, "step4_assumption_check.csv"))
write_csv(term_sensitivity, file.path(out_dir, "step4_term_sensitivity.csv"))
write_csv(threshold_table, file.path(out_dir, "step4_threshold_table.csv"))
write_csv(empirical_optima, file.path(out_dir, "step4_empirical_optima.csv"))
write_csv(p_star_vs_empirical, file.path(out_dir, "step4_pstar_vs_empirical.csv"))
write_csv(expected_vs_realized, file.path(out_dir, "step4_expected_vs_realized.csv"))
write_csv(bootstrap_summary, file.path(out_dir, "step4_bootstrap_summary.csv"))
write_csv(sens_grid, file.path(out_dir, "step4_sensitivity_grid.csv"))
saveRDS(list(boot = boot, boot_band = boot_band, B = B, seed = 44, principal_usd = principal,
             scenarios = scenarios, curves = curves),
        file.path(out_dir, "step4_results.rds"))

# -----------------------------------------------------------------------------
# 7. Console report
# -----------------------------------------------------------------------------
options(width = 200, pillar.sigfig = 5)
cat("\n== Assumption check ==\n"); print(as.data.frame(assumption_check), digits = 5)
cat("\n== Term sensitivity (base) ==\n"); print(as.data.frame(term_sensitivity), digits = 4)
cat("\n== Platt, base scenario, report thresholds ==\n")
print(as.data.frame(threshold_table |> filter(score == "Platt", scenario == "Base") |>
  select(threshold, approved, declined, approval_rate, TP_declined_target1, FP_declined_target0,
         TN_approved_target0, FN_approved_target1, precision, recall, specificity, fpr,
         target_rate_approved, profit_per_applicant_usd, profit_per_approved, improvement_per_applicant, profit_total_usd, improvement_total_usd)), digits = 4)
cat("\n== Empirical optima ==\n"); print(as.data.frame(p_star_vs_empirical), digits = 4)
cat("\n== Expected (model) vs realized profit per applicant, Platt ==\n"); print(as.data.frame(expected_vs_realized), digits = 4)
cat("\n== Bootstrap (B = 1000) ==\n"); print(as.data.frame(bootstrap_summary), digits = 4)
cat("\n== Sensitivity grid ==\n"); print(as.data.frame(sens_grid), digits = 3)
