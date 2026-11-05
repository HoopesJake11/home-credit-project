# Running the presentation R files in Positron

## Setup (once, about 2 minutes)

1. Download these three files and put them in your `homecredit-eda/` folder, next to `modeling.qmd`:
   - `presentation_setup.R`
   - `01_business_impact.Rmd`
   - `02_personas.Rmd`
2. Open the `home-credit-project` folder in Positron and start Claude Code in the terminal.
3. Paste the prompts below one at a time.

The first run takes about 10 minutes. It re-runs your modeling.qmd code once to rebuild the holdout predictions, then saves them in `homecredit-eda/presentation_cache/`. After that, each file runs in seconds. Nothing in your existing files changes. Results land in `homecredit-eda/presentation_results/`.

---

## Prompt 1: Run the business impact numbers

```
In homecredit-eda/, render 01_business_impact.Rmd with rmarkdown::render(). Work from inside homecredit-eda/ so the relative paths in presentation_setup.R work. The first run rebuilds the model objects from modeling.qmd, which takes about 10 minutes, so let it finish.

When it's done:
1. Confirm the "Holdout AUC check" message is 0.7556. If it isn't, stop and tell me what it printed.
2. Show me presentation_results/business_impact_summary.md.
3. In plain English, tell me the three numbers that matter most for a business audience.

Don't edit modeling.qmd, data_preparation.R, or any existing file. If something errors, show me the error and propose a fix before changing anything.
```

## Prompt 2: Find the two personas

```
Render homecredit-eda/02_personas.Rmd the same way. It should load the cache from the last step in seconds.

Then:
1. Show me both candidate tables (approved and denied) and presentation_results/persona_summary.md.
2. Recommend which approved candidate and which denied candidate make the clearest story for a non-technical audience. A good pair has a believable job, a believable loan size, and two or three drivers that are easy to explain. If a different row number fits better, change approved_pick or denied_pick in the "pick" chunk and render again.
3. For each persona, write a 3-sentence plain-English explanation of why the model approved or denied them, using only the drivers in persona_summary.md. Don't claim causation.

Don't edit any file except approved_pick and denied_pick in 02_personas.Rmd.
```

## Prompt 3 (optional): Try a different decision rule

```
In 02_personas.Rmd, set deny_share to 0.05 and render again. Tell me whether both personas keep the same decision and how the risk cutoff changed. Then set it back to 0.10.
```

## Prompt 4: Package the results for the deck

```
Make one file, presentation_results/FOR_DECK.md, that contains:
- the full text of business_impact_summary.md and persona_summary.md
- the persona explanations you wrote
- the row numbers of the personas I picked

Then list every file in presentation_results/ so I can upload them.
```

---

## Send the results back

Upload `FOR_DECK.md` to the project thread, plus the PNG charts from `presentation_results/` if you want them. The thread will put the real numbers into the deck in place of the bracketed placeholders.

**Before committing to GitHub:** `presentation_cache/` holds model objects that are tens of MB. Either add it to `.gitignore` or don't commit it.
