# Business impact results (holdout, 61,502 applicants)

- Holdout AUC check: 0.7550
- Riskiest decile default rate: 27.2%; safest decile: 1.6%
- Flag riskiest 10%: catches 33.7% of defaults; approved default rate 8.07% -> 5.95% (26.3% lower)
- Same approval rate as 'no credit history, no loan' (85.7% approved): default rate 7.77% (rule) vs 5.43% (model); 200 fewer defaults per 10,000 applicants
- Thin-file applicants the model approves at that rate: 80.1%
- Same default rate as the rule (7.77%): model approves 99.3% vs 85.7% (1,367 more per 10,000 applicants)
