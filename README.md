# Australian Bank Product & Rate Tracker

Tracks the products, interest rates and fees that every Australian bank publishes under Open Banking (the Consumer Data Right), collected automatically every day, to show how the big four compare with the market and how quickly rates respond to Reserve Bank cash rate changes.

> **Status:** in development. This README will be completed as the project is built.
>
> **Not financial advice.** This project describes published product data. It does not recommend any product.

## Business questions

1. How quickly do big four mortgage and savings rates follow RBA cash rate changes, compared with challenger banks?
2. Where do the big four sit on rates and fees against the market, by product type?
3. Which banks changed products or rates this week?

## Data

- Public Product Reference Data published by banks under the Consumer Data Right (no customer data).
- The CDR Register, for the current list of banks and their public API addresses.
- RBA cash rate history.

## Architecture

```text
CDR Register + bank product APIs → Python collector (daily, GitHub Actions)
→ raw JSON kept → Azure SQL Database (raw → staging → mart) → Power BI
```

## Repository structure

```text
src/        Python: collect, load, checks
sql/        tables, views, validation
powerbi/    report file and screenshots
docs/       architecture, data dictionary, decisions, validation
.github/    scheduled collector workflow
```

## Tools

Python, SQL (Azure SQL Database), Power BI Desktop, GitHub Actions.
