\# Transportation Database and Machine Learning Project



\## Overview



This project develops a PostgreSQL database and machine learning pipeline to examine transportation choices between NYC Yellow Taxis and Citi Bike.



Using 2024 trip data, the project builds a relational database, implements normalized and wide feature-store designs, evaluates SQL queries and indexing strategies, and applies machine learning classification models to predict transportation mode.



\## Dataset



The project uses 2024 NYC Yellow Taxi and Citi Bike trip data.



\- 120,000 sampled Yellow Taxi trips

\- 120,000 sampled Citi Bike trips

\- 240,000 total trips



The dataset is balanced between transportation modes for classification purposes and does not represent actual transportation mode shares.



\## Project Structure



\- `src/` — SQL database script, Jupyter notebook, and Python dependencies

\- `data/` — Instructions for obtaining and preparing the datasets

\- `evaluation/` — Database performance and machine learning evaluation results

\- `report/` — Final project report

\- `presentation/` — Final presentation



\## Technologies



\- PostgreSQL

\- Python

\- Jupyter Notebook

\- SQLAlchemy

\- Pandas and NumPy

\- Scikit-learn

\- Matplotlib



\## Getting Started



1\. Install PostgreSQL and create the project database.

2\. Install the Python dependencies listed in `src/requirements.txt`.

3\. Download and prepare the required 2024 Yellow Taxi and Citi Bike datasets, following the instructions in `data/README.md`.

4\. Configure local database credentials in a `.env` file. Do not commit this file.

5\. Run the SQL script in `src/Transportation\_Database.sql` to create and populate the database.

6\. Open and execute `src/Transportation\_Project.ipynb` to run the analysis, database benchmarks, and machine learning models.



\## Project Components



\- Relational database design and implementation

\- SQL analytical queries and database indexing experiments

\- Normalized and wide feature-store implementations

\- Feature retrieval performance comparisons

\- Machine learning classification using Naive Bayes and Logistic Regression

\- Prediction storage and database auditing



\## Notes



This repository contains project code and documentation. Raw datasets and database credentials are not included.



