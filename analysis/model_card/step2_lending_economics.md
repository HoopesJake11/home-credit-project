# Step 2 — Consumer Lending Economics for Threshold Selection

*Home Credit Default Risk model card · research notes · compiled 2026-10-25*

These notes collect researched financial assumptions for picking an economically sensible probability-of-default cutoff for the final XGBoost model. They are **inputs to a later step**: no operating threshold is chosen here, because that needs out-of-fold probabilities and a calibration check first.

**Labels used throughout**

| Tag | Meaning |
|---|---|
| **[S]** | Directly sourced. The number appears in the cited document and was read from the primary source in this session. |
| **[D]** | Derived from the project's own Kaggle data, using `analysis/model_card/step2_dataset_loan_terms.R`. |
| **[C]** | Calculated from [S] or [D] values. The formula is shown. |
| **[A]** | Illustrative assumption. Not supported by a source; chosen to bracket a plausible range. |

Web access was available. Every [S] value was checked against the primary page or PDF text. Search-engine summaries were **not** relied on, and two of them proved wrong (see §7).

---

## 1. Source table

| # | Source | Publisher | Published / data period | Numerical evidence used | Product relevance | Link |
|---|---|---|---|---|---|---|
| S1 | Home Credit Default Risk data dictionary (`HomeCredit_columns_description.csv`) | Home Credit / Kaggle | Competition data, 2018 | TARGET definition (§2) | **Exact dataset** | local file, row 2 |
| S2 | *Home Credit B.V.: IFRS consolidated results for FY2018 and Q1 2019* (press release) | Home Credit B.V. | 28 Jun 2019; FY2018 and Q1 2019 | NIM 15.8% (FY2018; 14.6% FY2017). Cost-to-income 42.2% (FY2018), 39.4% (Q1 2019). Cost-of-risk 9.4% (end-2018), 8.3% (Q1 2019); CIS 1.8%, CEE −0.2% (end-2018). NPL coverage 126.7%. Nine countries. | **The lender that supplied the data.** The figures are consolidated across 9 countries; the data's country is not disclosed. | [homecredit.net PDF](https://www.homecredit.net/wp-content/uploads/2022/11/190628-HCBV-FY18_Q1_2019-Results-Announcement.pdf) |
| S3 | *Charge-Off and Delinquency Rates on Loans and Leases at Commercial Banks* (seasonally adjusted) | Federal Reserve Board | Released 25 Aug 2026; 2026:Q2 | Other consumer loans: 3.82% (2026:Q2), 4.69% (2024:Q3). Credit cards: 2.66% (2026:Q2). Charge-offs are "measured net of recoveries as a percentage of average loans and annualized." | U.S. banks. "Other consumer loans" is the closest category to unsecured installment loans (it includes auto). | [federalreserve.gov](https://www.federalreserve.gov/releases/chargeoff/chgallsa.htm) |
| S4 | *Profitability of Credit Card Operations of Depository Institutions* (35th report) | Federal Reserve Board | 2025 report; 2024 data | Large credit card banks, % of average assets: net interest income 10.16, noninterest income 6.34, noninterest expense 9.03, provisions 3.62, pretax return 3.87 (3.31 in 2023). All banks: pretax ROA 1.38. | **Credit cards.** Revolving, with interchange income. Materially different from installment loans. | [federalreserve.gov PDF](https://www.federalreserve.gov/publications/files/ccprofit2025.pdf) |
| S5 | Drechsler, Jung, Peng, Supera & Zhou, *Credit Card Banking*, Staff Report 1143 | Federal Reserve Bank of New York | Mar 2025, rev. Aug 2026 | Card rates average 22%, an 18% spread over the short rate. Charge-offs ~6%. Card ROA 6.8%. Default risk premium 4.3%. | **Credit cards.** Used only as context. | [newyorkfed.org](https://www.newyorkfed.org/research/staff_reports/sr1143) |
| S6 | *Consumer Credit – G.19*, Terms of Credit (not seasonally adjusted) | Federal Reserve Board | Released 7 Oct 2026 | 24-month personal loan rate at commercial banks: 11.86% (2026:Q2), 11.50% (2025). Credit card plans, all accounts: 20.94% (2026:Q2). | U.S. bank personal loans: an installment product, but a prime bank segment | [federalreserve.gov](https://www.federalreserve.gov/releases/G19/current/default.htm) |
| S7 | *Quarterly Banking Profile, Second Quarter 2026*, Table III-A | FDIC | Aug 2026; 2026:Q2 | All insured institutions: cost of funding earning assets 2.03%, NIM 3.32%, noninterest expense/assets 2.50%, net charge-offs/loans 0.57%. **Consumer Lenders group** (31 institutions): yield 7.82%, cost of funds 3.09%, NIM 4.73%, noninterest income/assets 1.41%, noninterest expense/assets 3.07%, net charge-offs/loans 0.96%. **Credit Card Banks group**: NIM 9.41%, net charge-offs 3.56%. | U.S. banks. The Consumer Lenders group is the closest U.S. bank analogue. | [fdic.gov PDF](https://www.fdic.gov/quarterly-banking-profile/quarterly-banking-profile-second-quarter-2026.pdf) |
| S8 | Basel Framework CRE32, *IRB approach: risk components* (in force 1 Jan 2023) | Basel Committee / BIS | Published 27 Mar 2020 | CRE32.6: F-IRB LGD 45% for senior unsecured claims on banks and FIs, 40% for other corporates. CRE32.58 A-IRB LGD **floors**: other unsecured retail 30%, QRRE 50%. | Regulatory capital parameters. The 30% figure is a **floor**, not an estimate of losses. | [bis.org](https://www.bis.org/basel_framework/chapter/CRE/32.htm?inforce=20230101&published=20200327) |
| S9 | *The Structure and Practices of the Debt Buying Industry* | U.S. Federal Trade Commission | 30 Jan 2013 | Debt buyers paid "an average of about 4 cents" per dollar of face value; older debt sold for less. 71% of the debt (by dollar) was credit card debt. | U.S. charged-off consumer debt, mostly credit cards. Gives a market price for recoveries at charge-off. | [ftc.gov](https://www.ftc.gov/node/46255) |
| S10 | *Q2 2026 Credit Industry Insights Report* (press release) | TransUnion | 6 Aug 2026; 2026:Q2 | Unsecured personal loans: average account balance **$8,437**; average debt per borrower $11,694; borrower-level 60+ DPD delinquency 3.81%. | U.S. unsecured personal loans | [newsroom.transunion.com](https://newsroom.transunion.com/Q2-2026-CIIR/) |
| S11 | *The Buy Now, Pay Later Market: Data Spotlight* | CFPB | Dec 2025; 2019–2023 data | Defines charge-off as debts "deemed severely delinquent and written off as bad debt"; BNPL loan charge-off rate 1.83% (2023). | **BNPL**, a very different product. Used only for the definition. | [consumerfinance.gov PDF](https://files.consumerfinance.gov/f/documents/cfpb_bnpl-market-report_2025-12.pdf) |

**Already in the project.** The EDA business-problem statement ([eda.qmd](../../homecredit-eda/eda.qmd), §Business Problem) frames the two costly errors: approving a defaulter and rejecting a good borrower. It contains **no** numeric financial assumptions. [modeling.qmd](../../homecredit-eda/modeling.qmd) explicitly states that no cost-benefit analysis was done. Nothing earlier in the project is being reused or overridden.

---

## 2. What TARGET = 1 actually means

The data dictionary [S1] says:

> "Target variable (1 - client with payment difficulties: he/she had late payment more than X days on at least one of the first Y installments of the loan in our sample, 0 - all other cases)"

The four ideas below are often run together, but they are different:

| Concept | Meaning | Relationship to TARGET |
|---|---|---|
| **Payment difficulty** (TARGET = 1) | At least one installment more than *X* days late, within the first *Y* installments | This is the label. **X and Y are not disclosed.** |
| **Default** | Typically 90+ days past due, or unlikely to pay (the Basel definition) | Only some TARGET = 1 cases reach it. Late payers can cure. If X is small, many will. |
| **Charge-off** | The lender writes the balance off as uncollectible. Charge-offs are reported net of recoveries [S3]; CFPB: "written off as bad debt" [S11]. | Happens after default, typically months later |
| **Financial loss** | Exposure at default × loss given default, after recoveries and collection costs, and net of any interest or fees already collected | What a threshold should be weighed against |

What this means for the model card:

1. **TARGET = 1 is not a write-off.** A borrower can be late once and then repay in full, possibly paying late fees on top. Treating every TARGET = 1 as a 100% principal loss overstates losses and pushes the cutoff too low.
2. **TARGET = 0 is not guaranteed repayment.** A borrower who paid the first Y installments on time can still default later. The label cannot see that, so the simple model below assumes TARGET = 0 loans are fully repaid. That leans optimistic.
3. **"Early" means high exposure.** Because the event occurs within the first Y installments, little principal has been repaid when trouble begins. That supports an EAD close to 100% of principal.
4. **The labeled data are approved loans only.** Outcomes of rejected applicants are unknown (selection bias). Any threshold applies with confidence only to applicants who resemble past approvals.

**Assumptions needed to turn TARGET into money:**

- **c**, the *loss conversion rate*: the share of TARGET = 1 loans that end in charge-off. **No source found** [A].
- **EAD**: the share of principal still outstanding when a TARGET = 1 loan defaults [C from an amortization schedule, with an assumed payment count A].
- **LGD**: the share of EAD not recovered [S range, base value A].
- **Profit if repaid**: the lifetime contribution margin of a good loan [C from S2 or S7].
- **Cured TARGET = 1 loans** (share 1 − c): assumed to contribute **zero** net profit, with late fees offsetting collection effort [A]. This is a simplifying choice; §6 discusses it.

---

## 3. Evidence by topic

### 3.1 Typical principal amounts

| Evidence | Value | Tag |
|---|---|---|
| U.S. unsecured personal loan, average account balance (2026:Q2) | $8,437 | [S10] |
| Kaggle training data, `AMT_CREDIT` median (all 307,511 rows) | 513,531 currency units | [D] |
| Kaggle: cash loans (90.5% of rows) / revolving loans (9.5%), median `AMT_CREDIT` | 540,000 / 270,000 | [D] |
| Kaggle: `AMT_CREDIT` 10th–90th percentile | 180,000 – 1,133,748 | [D] |
| Kaggle: mean `AMT_CREDIT`, TARGET = 0 vs TARGET = 1 | 602,648 vs 557,779 | [D] |

**The dataset's currency is not disclosed**, so Kaggle amounts cannot be converted to dollars. This doesn't matter for the threshold: in the per-loan model, profit and loss both scale with principal, so **the break-even probability does not depend on loan size**. Everything below is expressed **per unit of principal**. The $8,437 figure is used only to make the dollar amounts concrete.

### 3.2 Pricing and profit when a loan is repaid

| Evidence | Value | Tag |
|---|---|---|
| Home Credit NIM, FY2018 | 15.8% | [S2] |
| Home Credit cost-to-income ratio, FY2018 / Q1 2019 | 42.2% / 39.4% | [S2] |
| Approved prior **cash** loans in `previous_application.csv` (312,536 loans; 50,000 sampled): median term 24 months; implied nominal APR median **40.0%** (IQR 30.1%–53.4%); total repaid / principal median 1.41 | — | [D] |
| Approved prior **consumer (POS)** loans: median term 10 months; implied APR median 40.1% | — | [D] |
| U.S. bank 24-month personal loan rate, 2026:Q2 | 11.86% | [S6] |
| FDIC Consumer Lenders group, 2026:Q2: NIM 4.73%, noninterest income 1.41%, noninterest expense 3.07% (of assets) | — | [S7] |
| Large credit card banks, 2024: pretax return 3.87% of assets | — | [S4] |

The implied APR solves `AMT_CREDIT = AMT_ANNUITY × (1 − (1 + r)^−n) / r`, assuming monthly installments. `AMT_ANNUITY` may include insurance or fees, and these are prior loans, not the current ones. The figure describes the **contractual price** charged to Home Credit customers, which is far above the U.S. bank personal loan rate. It is **not** a profit margin, because funding, operating and credit costs must still come out.

**Annual pre-provision contribution margin (m).** This is margin before credit losses, which are counted separately so they aren't counted twice:

- Base, from Home Credit [C]: m = NIM × (1 − cost-to-income) = 15.8% × (1 − 0.422) = **9.13% per year** of loan balance. Home Credit's cost-to-income ratio divides operating cost by *total* operating income, which includes fees and commissions. Applying it to NIM alone therefore **understates** the true pre-provision margin, so this choice leans conservative.
- Optimistic [C]: 15.8% × (1 − 0.394) = **9.57%** (uses the lower Q1 2019 cost-to-income).
- Conservative, U.S. consumer-lender bank economics [C]: 4.73% + 1.41% − 3.07% = **3.07%** of assets per year. These are asset-based ratios for U.S. banks, used as a low-margin bound.

**Lifetime exposure (T).** For a 24-month amortizing loan at 40% APR (the dataset medians [D]), average outstanding balance × years = **1.171 principal-years** [C]. Total payments come to 1.4685 × principal.

**Profit if repaid** = m × T [C]: conservative 0.036, base **0.107**, optimistic 0.112 per unit of principal.

### 3.3 Cost of funding and servicing

- Funding is already netted out inside NIM (NIM = interest income − interest expense). Operating and servicing costs are netted out by the cost-to-income ratio or by noninterest expense. **Neither is subtracted again** anywhere below.
- For reference [S7]: U.S. cost of funding earning assets was 2.03% for all banks and 3.09% for the Consumer Lenders group. Home Credit's own funding cost was not reported in S2, so it remains **unverified**. Its emerging-market funding costs are probably higher than U.S. levels, but that is not sourced.
- Funding cost on a defaulted balance during collections is **not modeled separately**. Economic LGD conventionally includes discounting of recoveries, so it is treated as part of LGD.

### 3.4 Loss given default and recoveries

| Evidence | Implied LGD | Tag | Caveat |
|---|---|---|---|
| Basel A-IRB floor, other unsecured retail | ≥ 30% | [S8] | A regulatory minimum, not an estimate |
| Basel F-IRB senior unsecured (banks and FIs) | 45% | [S8] | Corporate and financial-institution claims, not retail. A widely used benchmark only. |
| FTC: charged-off debt sells for ~4¢ per $1 | ≈ 96% if the lender sells at charge-off | [S9]→[C] | U.S., 2013, mostly cards. Lenders that collect in-house may recover more. |
| Fed charge-off rates are net of recoveries | — | [S3] | Confirms that recoveries must not be counted twice |
| Home Credit NPL coverage 126.7% | — | [S2] | Provisions exceed NPL balances, consistent with high expected LGD. Not an LGD estimate itself. |

**No primary source gave an empirical LGD for unsecured consumer installment loans.** Some secondary web pages quote "40–70%" or "45–75%", but they are not authoritative and are **not** used. The scenarios therefore use the sourced endpoints, 45% and 96%, as optimistic and conservative values, and their midpoint, **70.5%**, as the base [A/C]. Recovery rate = 1 − LGD: 55% / 29.5% / 4%.

### 3.5 How lenders calculate expected loss

The standard credit-risk decomposition is **Expected Loss = PD × LGD × EAD**. It is the basis of IRB capital (Basel CRE31/32, whose risk components PD, LGD and EAD are defined in CRE32 [S8]) and of lifetime loss allowances under IFRS 9 and CECL. *(The CRE32 excerpt read in this session defines the components but does not print the EL equation itself; the formula is standard but no paragraph number is cited for it.)* Home Credit reports under IFRS 9 [S2]. Its "cost of risk" is the provision charge as a share of loans: an **accounting provision**, not realized loss.

---

## 4. Financial assumptions table (per unit of principal)

The dollar columns use P = $8,437 [S10] for illustration only. The break-even probability is the same at any principal.

| Input | Conservative | Base | Optimistic | Tag | Justification |
|---|---|---|---|---|---|
| Principal P | 1 ($8,437) | 1 ($8,437) | 1 ($8,437) | S10 for $ | Break-even does not depend on P |
| Annual pre-provision margin m | 3.07% | 9.13% | 9.57% | C from S7 / S2 / S2 | §3.2 |
| Lifetime principal-years T | 1.171 | 1.171 | 1.171 | C from D | 24-mo., 40% APR amortization |
| **Profit if repaid G = m·T** | **0.036 ($303)** | **0.107 ($902)** | **0.112 ($946)** | C | Funding and opex already inside m |
| Installments paid before default k | 0 | 3 | 6 | A | TARGET is an early-installment event |
| **Default exposure EAD** | **1.000** | **0.914** | **0.818** | C | Balance after k of 24 payments at 40% APR |
| Recovery rate | 4% | 29.5% | 55% | S9 / C / S8 | §3.4 |
| **LGD** | **96%** | **70.5%** | **45%** | S9→C / A (midpoint) / S8 | §3.4 |
| Net loss given a true default = EAD·LGD | 0.960 ($8,100) | 0.644 ($5,434) | 0.368 ($3,107) | C | |
| Loss conversion c = P(charge-off \| TARGET = 1) | 100% | 50% | 25% | **A** | No source. The largest uncertainty. |
| **Loss if TARGET = 1: L = c·EAD·LGD** | **0.960 ($8,100)** | **0.322 ($2,717)** | **0.092 ($777)** | C | Cured loans assumed to earn 0 |
| **Break-even p\* = G / (G + L)** | **0.036** | **0.249** | **0.549** | C | §5 |
| Implied lifetime loss rate at 8.07% prevalence = 0.0807·L | 7.7% | 2.6% | 0.7% | C | Sanity check below |

**Sanity check against Home Credit's reported cost of risk [S2].** In the base case, a portfolio with Kaggle's 8.07% TARGET rate loses about 2.6% of principal over roughly 1.2 years, about 2.2% a year. That sits between Home Credit's 2018 cost of risk in CIS (1.8%) and its consolidated level (9.4%, driven by Asian growth markets). The check rules out nothing decisive, because cost of risk is an accounting provision for different portfolios, but the base case is not out of line with the lender's own experience.

**What was avoided:**

- Recoveries appear only inside LGD.
- Funding and operating costs appear only inside m.
- Credit losses are excluded from m and appear only in L.
- Interest collected before default is ignored, which leans conservative.

---

## 5. Break-even logic (no operating threshold chosen)

For one applicant with *calibrated* probability p of TARGET = 1:

```
Expected profit of approving  = (1 − p) × G  −  p × L
Expected profit of declining  = 0
Break-even:  (1 − p*) G = p* L   ⇒   p* = G / (G + L)
```

- **Approve** when p < p\*: the expected margin from good loans outweighs the expected loss.
- **Decline**, or refer for manual review, when p > p\*.
- p\* depends only on the **ratio** L/G. Larger losses or thinner margins push the cutoff down, so the lender declines more applicants.

**Sensitivity of p\* to the two least-supported inputs** (base G = 0.107, EAD = 0.914) [C]:

| c \ LGD | 45% | 60% | 70.5% | 80% | 96% |
|---|---|---|---|---|---|
| 25% | 0.510 | 0.438 | 0.399 | 0.369 | 0.328 |
| 50% | 0.342 | 0.281 | **0.249** | 0.226 | 0.196 |
| 75% | 0.258 | 0.206 | 0.181 | 0.163 | 0.140 |
| 100% | 0.206 | 0.163 | 0.142 | 0.128 | 0.109 |

The cutoff ranges from about 0.11 to 0.51 across plausible values. **The choice of threshold depends more on c and LGD than on anything the model does.**

**Context from Step 1** (Kaggle test predictions, which are *not* calibrated evidence): mean 0.083, 95th percentile 0.241, 99th percentile 0.354, maximum 0.625.

- At the **base** p\* of 0.249, roughly 5% of applicants would be declined.
- At the **optimistic** 0.549, almost nobody would be.
- At the **conservative** 0.036, the large majority would be.

These are rough readings from an uncalibrated distribution, given only to show the scale.

---

## 6. Limitations and open issues

1. **The loss conversion c is unsourced.** X and Y in the TARGET definition are not disclosed, and no public source links Home Credit's "payment difficulties" to charge-off. This is the single most influential assumption.
2. **No empirical unsecured-installment LGD from a primary source.** The 45% and 96% endpoints come from adjacent contexts: a corporate/FI regulatory value and U.S. credit-card debt sales from 2013.
3. **Profit model approximations.**
   - NIM and cost-to-income are portfolio-wide 2018 figures across 9 countries.
   - The term and APR come from *previous* applications.
   - The current loans' terms are unknown: `CNT_PAYMENT` is absent from `application_train`, and a median credit/annuity ratio of 20.7 suggests longer terms than 24 months.
   - Cured TARGET = 1 loans are assumed to earn 0; if they earn G, p\* rises.
   - Later defaults among TARGET = 0 loans are ignored; including them would lower p\*.
4. **Calibration is required.** p\* is only valid against *calibrated* probabilities. The final model is unadjusted XGBoost, so it may be close, but that hasn't been checked. Step 3 must measure calibration on out-of-fold or holdout predictions, and recalibrate if needed, before p\* is applied.
5. **Selection bias.** The training data are past approvals. Applying the cutoff to the full applicant population, including people who were previously declined, is extrapolation.
6. **Currency, country and period.** The dataset's country, currency and time period are undisclosed. U.S. 2024–2026 bank figures describe a different market and are used only for bounds and context.
7. **Fairness interaction.** One cutoff applied to groups with different score distributions can produce different approval and error rates by gender or education. This feeds into the fairness section of the model card.

---

## 7. Verification log

- Every [S] value was read from the primary HTML page or extracted PDF text in this session.
- **Search-summary errors caught:**
  - A search snippet gave the FDIC Q2 2026 cost of funds as 1.85% and noninterest expense/assets as 2.64%. The QBP PDF shows **2.03%** and **2.50%** for all institutions. The PDF values are used.
  - A search snippet gave Home Credit's NIM as "15.5% in 2019". That figure was **not** found in any primary document and is not used. The 15.8% (FY2018) comes from S2.
- Dataset figures can be reproduced with `Rscript analysis/model_card/step2_dataset_loan_terms.R` (run from the repository root). Its outputs are the `step2_*.csv` files in the git-ignored `models/model_card/` folder (seed 2 for the 50,000-loan sample).
- No model was retrained, no cross-validation was run, and no existing project file was modified.
