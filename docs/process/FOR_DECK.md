# For the deck

Everything below comes from the 61,502 holdout applicants the model never saw in training.

**Model note:** the presentation model was refit with the original tuned settings and scores a holdout AUC of 0.7550 (the README and modeling.html report 0.7556 from the original run). On the slides, say "about 0.755" or footnote the refit.

## Personas picked

| Persona | Holdout row | Candidate # in 02_personas.Rmd | Decision rule |
|---|---|---|---|
| Approved | 46906 | approved_pick = 3 | Deny the riskiest 10% (risk at least 17.9%) |
| Denied | 22892 | denied_pick = 1 | Deny the riskiest 10% (risk at least 17.9%) |

Both personas keep the same decision under a stricter rule that denies only the riskiest 5% (risk at least 23.5%).

## Persona explanations

**Approved persona (row 46906):** The model rated her at 3.6% risk, well below the average applicant's 8.0%, even though she has no credit bureau record. Her outside credit scores were the biggest factor pointing toward lower risk, followed by her university education. Her loan was for exactly the price of the goods she was buying, which the model also associates with lower risk, and nothing in her application pushed her risk up meaningfully.

**Denied persona (row 22892):** The model rated him at 60.7% risk, among the very highest of all 61,502 holdout applicants, so he falls well inside the riskiest 10% that this rule denies. The strongest signal was his very low outside credit scores, and he was also asking to borrow about 42% more than the price of the goods he was buying. Applicants with low outside scores and loans much larger than the purchase price have historically had payment difficulties more often, and no part of his application pointed the other way.

These drivers show what the model's score is associated with, not what causes default.

---

## Full text: business_impact_summary.md

# Business impact results (holdout, 61,502 applicants)

- Holdout AUC check: 0.7550
- Riskiest decile default rate: 27.2%; safest decile: 1.6%
- Flag riskiest 10%: catches 33.7% of defaults; approved default rate 8.07% -> 5.95% (26.3% lower)
- Same approval rate as 'no credit history, no loan' (85.7% approved): default rate 7.77% (rule) vs 5.43% (model); 200 fewer defaults per 10,000 applicants
- Thin-file applicants the model approves at that rate: 80.1%
- Same default rate as the rule (7.77%): model approves 99.3% vs 85.7% (1,367 more per 10,000 applicants)

---

## Full text: persona_summary.md

The empty "-  ()" line under the denied persona means nothing in his application lowered his risk; leave it off the slide.

# Persona results

Rule: deny the riskiest 10% (predicted risk at least 17.9%).

## Approved persona (holdout row 46906)
- Predicted risk: 3.6% (average applicant 8.0%); riskier than 31.5% of applicants; decision: Approve
- Actual outcome: repaid
- Age 29, F, Married; employed 4.3 years; State servant
- Occupation: Core staff; education: Higher education; housing: House / apartment; children: 0
- Loan 540,000 (Cash loans) for goods priced 540,000, loan-to-value 1.00; income 112,500
- Outside score average 0.53 from 2 score(s); credit bureau record: no; blank fields: 8
- Biggest factors lowering risk:
  - Outside credit scores (-0.3)
  - Education (-0.2)
  - Loan vs. price of goods (-0.1)
- Biggest factors raising risk:
  - Other application details (0.05)
  - Credit bureau history (0.03)
  - Age (0.02)

## Denied persona (holdout row 22892)
- Predicted risk: 60.7% (average applicant 8.0%); riskier than 100.0% of applicants; decision: Deny
- Actual outcome: had payment difficulties
- Age 39, M, Civil marriage; employed 2.3 years; Working
- Occupation: Drivers; education: Secondary / secondary special; housing: House / apartment; children: 1
- Loan 640,080 (Cash loans) for goods priced 450,000, loan-to-value 1.42; income 202,500
- Outside score average 0.10 from 2 score(s); credit bureau record: yes; blank fields: 49
- Biggest factors lowering risk:
  -  ()
- Biggest factors raising risk:
  - Outside credit scores (1.62)
  - Loan vs. price of goods (0.35)
  - Loan size and payments (0.28)

