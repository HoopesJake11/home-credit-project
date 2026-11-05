# Step 2 support: describe loan size and implied pricing from the Kaggle data
# itself. Read-only on existing files; no model is fit. Outputs to
# models/model_card/. Amounts are in the dataset's (undisclosed) currency.
#
#   "C:/Program Files/R/R-4.5.2/bin/Rscript.exe" analysis/model_card/step2_dataset_loan_terms.R

suppressPackageStartupMessages(library(tidyverse))
out_dir <- "models/model_card"

app <- read_csv("homecredit-eda/data/application_train.csv", show_col_types = FALSE,
                col_select = c(SK_ID_CURR, TARGET, NAME_CONTRACT_TYPE, AMT_CREDIT,
                               AMT_ANNUITY, AMT_GOODS_PRICE, AMT_INCOME_TOTAL))

q <- function(x) quantile(x, c(.1, .25, .5, .75, .9), na.rm = TRUE)
app_summary <- app |>
  group_by(NAME_CONTRACT_TYPE) |>
  summarise(n = n(), share = n() / nrow(app), default_rate = mean(TARGET),
            credit_mean = mean(AMT_CREDIT), credit_median = median(AMT_CREDIT),
            annuity_median = median(AMT_ANNUITY, na.rm = TRUE),
            credit_to_annuity_median = median(AMT_CREDIT / AMT_ANNUITY, na.rm = TRUE),
            .groups = "drop")
credit_quantiles <- enframe(q(app$AMT_CREDIT), "quantile", "AMT_CREDIT")
credit_by_target <- app |> group_by(TARGET) |>
  summarise(n = n(), credit_mean = mean(AMT_CREDIT), credit_median = median(AMT_CREDIT))

# Implied pricing from previous applications that were approved and have a
# known term: solve AMT_CREDIT = AMT_ANNUITY * (1 - (1 + r)^-n) / r for the
# monthly rate r (annuity assumed monthly). This is the lender's contractual
# yield on those loans, not its profit.
prev <- read_csv("homecredit-eda/data/previous_application.csv", show_col_types = FALSE,
                 col_select = c(NAME_CONTRACT_TYPE, NAME_CONTRACT_STATUS, AMT_CREDIT,
                                AMT_ANNUITY, CNT_PAYMENT, RATE_INTEREST_PRIMARY))

implied_rate <- function(pv, pmt, n) {
  f <- function(r) pmt * (1 - (1 + r)^-n) / r - pv
  if (pmt * n <= pv) return(0)  # zero (or negative) interest contract
  tryCatch(uniroot(f, c(1e-9, 1), tol = 1e-10)$root, error = function(e) NA_real_)
}

approved <- prev |>
  filter(NAME_CONTRACT_STATUS == "Approved", NAME_CONTRACT_TYPE %in% c("Cash loans", "Consumer loans"),
         AMT_CREDIT > 0, AMT_ANNUITY > 0, CNT_PAYMENT > 0)
set.seed(2)
approved_s <- approved |> group_by(NAME_CONTRACT_TYPE) |> slice_sample(n = 50000) |> ungroup()
approved_s$monthly_rate <- pmap_dbl(list(approved_s$AMT_CREDIT, approved_s$AMT_ANNUITY,
                                         approved_s$CNT_PAYMENT), implied_rate)
approved_s <- approved_s |>
  mutate(apr_nominal = 12 * monthly_rate,
         total_repaid_over_principal = AMT_ANNUITY * CNT_PAYMENT / AMT_CREDIT)

pricing <- approved_s |>
  group_by(NAME_CONTRACT_TYPE) |>
  summarise(n_sampled = n(), n_approved_total = NA_integer_,
            term_median_months = median(CNT_PAYMENT),
            apr_p25 = quantile(apr_nominal, .25, na.rm = TRUE),
            apr_median = median(apr_nominal, na.rm = TRUE),
            apr_p75 = quantile(apr_nominal, .75, na.rm = TRUE),
            share_zero_rate = mean(monthly_rate == 0, na.rm = TRUE),
            repaid_over_principal_median = median(total_repaid_over_principal),
            credit_median = median(AMT_CREDIT), .groups = "drop") |>
  mutate(n_approved_total = as.integer(table(approved$NAME_CONTRACT_TYPE)[NAME_CONTRACT_TYPE]))

rate_primary <- prev |> summarise(non_missing = sum(!is.na(RATE_INTEREST_PRIMARY)),
                                  median = median(RATE_INTEREST_PRIMARY, na.rm = TRUE))

write_csv(app_summary, file.path(out_dir, "step2_app_contract_summary.csv"))
write_csv(credit_quantiles, file.path(out_dir, "step2_app_credit_quantiles.csv"))
write_csv(credit_by_target, file.path(out_dir, "step2_app_credit_by_target.csv"))
write_csv(pricing, file.path(out_dir, "step2_prev_implied_pricing.csv"))

options(width = 150, pillar.sigfig = 5)
print(app_summary, width = Inf); print(credit_quantiles); print(credit_by_target)
print(pricing, width = Inf); print(rate_primary)
