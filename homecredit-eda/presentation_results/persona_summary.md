# Persona results

Rule: deny the riskiest 10% (predicted risk at least 17.9%).

These two applicants were intentionally selected as illustrative examples, not a representative sample.
Contributions are log-odds SHAP values: they show what the model's score is associated with, not what causes default.

## Approved persona (holdout row 46906)
- Predicted risk: 3.6% (average applicant 8.0%); risk rank 42,130 of 61,502 (1 = riskiest); decision: Approve
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
- Protected characteristics: gender -0.08, age +0.02 (log-odds)

## Denied persona (holdout row 22892)
- Predicted risk: 60.7% (average applicant 8.0%); risk rank 1 of 61,502 (1 = riskiest); decision: Deny
- Actual outcome: had payment difficulties
- Age 39, M, Civil marriage; employed 2.3 years; Working
- Occupation: Drivers; education: Secondary / secondary special; housing: House / apartment; children: 1
- Loan 640,080 (Cash loans) for goods priced 450,000, loan-to-value 1.42; income 202,500
- Outside score average 0.10 from 2 score(s); credit bureau record: yes; blank fields: 49
- Biggest factors lowering risk:
  - None: no theme moved the predicted risk in this direction
- Biggest factors raising risk:
  - Outside credit scores (1.62)
  - Loan vs. price of goods (0.35)
  - Loan size and payments (0.28)
- Protected characteristics: gender +0.13, age +0.07 (log-odds)

