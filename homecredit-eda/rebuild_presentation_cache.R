# rebuild_presentation_cache.R
# Rebuilds presentation_cache/model_objects.rds with the final model fixed to
# the hyperparameters modeling.qmd originally selected (holdout AUC 0.7556),
# as reported in modeling.html and the README.
#
# Re-running modeling.qmd's randomized search on another machine / package
# version can pick different settings, so this script skips the search and
# reuses modeling.qmd's own code for everything else: the setup, data loading,
# holdout split, the caret-compatible XGBoost method, the final fit, and the
# holdout AUC. modeling.qmd itself is read, never changed.
#
# Run from homecredit-eda/:  Rscript rebuild_presentation_cache.R

stopifnot("Run from homecredit-eda/ (modeling.qmd not found)" = file.exists("modeling.qmd"))

# Pull named R chunks out of modeling.qmd, keyed by their `#| label:`.
qmd    <- readLines("modeling.qmd")
starts <- grep("^```\\{r", qmd)
ends   <- vapply(starts, function(s) s + which(qmd[(s + 1):length(qmd)] == "```")[1], integer(1))
chunks <- Map(function(s, e) qmd[(s + 1):(e - 1)], starts, ends)
names(chunks) <- vapply(chunks, function(code) {
  lab <- grep("^#\\| label:", code, value = TRUE)
  if (length(lab)) trimws(sub("^#\\| label:", "", lab[1])) else ""
}, character(1))

run_chunk <- function(label) {
  message("Running modeling.qmd chunk: ", label)
  eval(parse(text = chunks[[label]]), envir = globalenv())
}

run_chunk("setup")
run_chunk("load-data")
run_chunk("holdout-split")
run_chunk("xgb-caret-compat")

# The hyperparameters from the original randomized search (modeling.html,
# "Selected hyperparameters (best_xgb_params)"; README "Model choice").
best_xgb_params <- data.frame(nrounds = 300, max_depth = 2, eta = 0.047,
                              gamma = 4, colsample_bytree = 0.95,
                              min_child_weight = 10, subsample = 0.86)

# Same as modeling.qmd's "final-data" chunk, minus its summary table, which
# refers to the exploration sample this script does not build.
development_model_data <- development_data |>
  mutate(TARGET = factor(if_else(TARGET == 1, "Default", "NoDefault"),
                         levels = c("Default", "NoDefault"))) |>
  select(-SK_ID_CURR)

holdout_model_data <- holdout_data |>
  mutate(TARGET = factor(if_else(TARGET == 1, "Default", "NoDefault"),
                         levels = c("Default", "NoDefault"))) |>
  select(-SK_ID_CURR)

# Formatting helper the AUC chunk uses (defined in modeling.qmd's
# "comparison-values" chunk).
fmt <- function(x) sprintf("%.4f", x)

run_chunk("fit-final-internal")
run_chunk("final-internal-auc")

message(sprintf("Development AUC: %.4f | Holdout AUC: %.4f (modeling.qmd reported 0.7639 / 0.7556)",
                development_auc, holdout_auc))

dir.create("presentation_cache", showWarnings = FALSE)
saveRDS(list(final_internal_xgb = final_internal_xgb,
             holdout_data       = holdout_data,
             holdout_prob       = holdout_prob,
             holdout_auc        = holdout_auc),
        file.path("presentation_cache", "model_objects.rds"))
message("Wrote presentation_cache/model_objects.rds")
