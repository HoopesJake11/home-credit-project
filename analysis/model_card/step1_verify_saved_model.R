# Step 1 of the model card: check that the saved final model reproduces the
# Kaggle submission. Read-only with respect to existing project files; all
# outputs go to models/model_card/ (git-ignored). No model is trained here.
#
# Run from the repository root:
#   "C:/Program Files/R/R-4.5.2/bin/Rscript.exe" analysis/model_card/step1_verify_saved_model.R

suppressPackageStartupMessages({
  library(tidyverse)
  library(caret)
  library(xgboost)
})

out_dir <- "models/model_card"
model_path      <- "models/final_home_credit_xgb.rds"
test_path       <- "homecredit-eda/data/prepared/test_prepared.rds"
submission_path <- "submissions/home_credit_xgboost_submission.csv"
sample_path     <- "homecredit-eda/data/sample_submission.csv"

file_info <- tibble(file = c(model_path, test_path, submission_path),
                    bytes = file.size(file),
                    modified = format(file.mtime(file)),
                    md5 = unname(tools::md5sum(file)))

final_model   <- readRDS(model_path)
test_prepared <- readRDS(test_path)
submission    <- read_csv(submission_path, show_col_types = FALSE)
sample_sub    <- read_csv(sample_path, show_col_types = FALSE)

# Same preprocessing as modeling.qmd (kaggle-data / kaggle-submission chunks):
# drop SK_ID_CURR, keep the prepared column order, let caret's stored formula
# terms do the dummy encoding, take the probability of the "Default" level.
kaggle_test_x <- test_prepared |> select(-SK_ID_CURR)

model_predictors <- setdiff(names(final_model$trainingData), ".outcome")
stopifnot(identical(model_predictors, names(kaggle_test_x)))

prob <- predict(final_model, newdata = kaggle_test_x, type = "prob")
stopifnot(identical(names(prob), c("Default", "NoDefault")))

regenerated <- tibble(SK_ID_CURR = test_prepared$SK_ID_CURR,
                      TARGET     = prob$Default)

# Align by ID, never by position.
comparison <- submission |>
  rename(TARGET_submitted = TARGET) |>
  left_join(rename(regenerated, TARGET_regenerated = TARGET), by = "SK_ID_CURR") |>
  mutate(abs_diff = abs(TARGET_regenerated - TARGET_submitted))

tol <- 1e-6
checks <- tibble(
  Check = c("Regenerated predictions = 48,744",
            "Submission rows = 48,744",
            "Submission columns exactly SK_ID_CURR, TARGET",
            "No duplicate SK_ID_CURR in submission",
            "No duplicate SK_ID_CURR in regenerated",
            "Same SK_ID_CURR set (submission vs regenerated)",
            "Same SK_ID_CURR set (submission vs Kaggle test file)",
            "Submission order matches sample_submission.csv",
            "Every submitted ID found a regenerated prediction",
            "No missing predictions",
            "Regenerated probabilities within [0, 1]",
            sprintf("Max |difference| <= %g", tol)),
  Passed = c(nrow(regenerated) == 48744,
             nrow(submission) == 48744,
             identical(names(submission), c("SK_ID_CURR", "TARGET")),
             !anyDuplicated(submission$SK_ID_CURR),
             !anyDuplicated(regenerated$SK_ID_CURR),
             setequal(submission$SK_ID_CURR, regenerated$SK_ID_CURR),
             setequal(submission$SK_ID_CURR, test_prepared$SK_ID_CURR),
             identical(as.numeric(submission$SK_ID_CURR), as.numeric(sample_sub$SK_ID_CURR)),
             !anyNA(comparison$TARGET_regenerated),
             !anyNA(comparison$TARGET_submitted),
             all(between(regenerated$TARGET, 0, 1)),
             max(comparison$abs_diff) <= tol)
)

diff_summary <- tibble(
  Metric = c("Max |difference|", "Mean |difference|", "Rows with |difference| > 1e-6",
             "Rows with |difference| > 1e-9", "Rows exactly equal", "Pearson correlation",
             "Spearman correlation"),
  Value = c(format(max(comparison$abs_diff), digits = 6),
            format(mean(comparison$abs_diff), digits = 6),
            format(sum(comparison$abs_diff > 1e-6)),
            format(sum(comparison$abs_diff > 1e-9)),
            format(sum(comparison$abs_diff == 0)),
            format(cor(comparison$TARGET_regenerated, comparison$TARGET_submitted), digits = 10),
            format(cor(comparison$TARGET_regenerated, comparison$TARGET_submitted,
                       method = "spearman"), digits = 10))
)

describe <- function(x) {
  q <- quantile(x, c(0.01, 0.05, 0.25, 0.5, 0.75, 0.95, 0.99))
  c(n = length(x), mean = mean(x), sd = sd(x), min = min(x), q, max = max(x))
}
distribution <- tibble(Statistic  = names(describe(comparison$TARGET_submitted)),
                       Submitted  = describe(comparison$TARGET_submitted),
                       Regenerated = describe(comparison$TARGET_regenerated)) |>
  mutate(Difference = Regenerated - Submitted)

# --- Save outputs (new files only) ---
saveRDS(comparison, file.path(out_dir, "step1_prediction_comparison.rds"))
write_csv(checks,       file.path(out_dir, "step1_checks.csv"))
write_csv(diff_summary, file.path(out_dir, "step1_difference_summary.csv"))
write_csv(distribution, file.path(out_dir, "step1_distribution.csv"))
write_csv(file_info,    file.path(out_dir, "step1_input_files.csv"))
writeLines(c(paste("Run at:", format(Sys.time(), tz = "UTC", usetz = TRUE)),
             capture.output(sessionInfo())),
           file.path(out_dir, "session_info.txt"))

# --- Console report ---
options(width = 120, pillar.sigfig = 7)
cat("\n== Input files ==\n");      print(file_info, width = 120)
cat("\n== Checks ==\n");           print(checks, n = Inf)
cat("\n== Differences ==\n");      print(diff_summary, n = Inf)
cat("\n== Distribution ==\n");     print(as.data.frame(distribution), digits = 8)
cat("\n== First 5 rows ==\n");     print(as.data.frame(head(comparison, 5)), digits = 10)
cat("\n== Largest differences ==\n")
print(as.data.frame(slice_max(comparison, abs_diff, n = 5, with_ties = FALSE)), digits = 12)
cat("\n== sessionInfo ==\n");      print(sessionInfo())
cat("\nALL CHECKS PASSED:", all(checks$Passed), "\n")
