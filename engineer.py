import pandas as pd
import numpy as np

df = pd.read_csv('dataset.csv')

def dpd(val):
    # 'm-2','m-1' = paid duly/early -> 0 days-past-due equivalent
    # 'm+0' = paid minimum on time -> 0
    # 'm+1'..'m+8' = months delinquent
    n = int(val.replace('m', ''))
    return max(n, 0)

pay_cols = [f'timeliness_{i}' for i in range(1, 7)]
for c in pay_cols:
    df[c + '_dpd'] = df[c].apply(dpd)

dpd_cols = [c + '_dpd' for c in pay_cols]
df['worst_dpd_6mo'] = df[dpd_cols].max(axis=1)
df['current_dpd'] = df['timeliness_1_dpd']          # most recent month (Sept 2005)
df['months_delinquent_6mo'] = (df[dpd_cols] > 0).sum(axis=1)
df['avg_dpd_6mo'] = df[dpd_cols].mean(axis=1).round(2)

bal_cols = [f'balance_{i}' for i in range(1, 7)]
pay_amt_cols = [f'payment_{i}' for i in range(1, 7)]
df['total_bill_6mo'] = df[bal_cols].sum(axis=1)
df['total_paid_6mo'] = df[pay_amt_cols].sum(axis=1)
df['payment_to_bill_ratio'] = np.where(df['total_bill_6mo'] > 0,
                                        (df['total_paid_6mo'] / df['total_bill_6mo']).round(3),
                                        1.0)
df['credit_utilization'] = (df['avg_balance'] / df['credit_limit']).round(3)

def age_band(a):
    if a < 25: return '<25'
    if a < 35: return '25-34'
    if a < 45: return '35-44'
    if a < 55: return '45-54'
    if a < 65: return '55-64'
    return '65+'
df['age_band'] = df['age'].apply(age_band)

def limit_band(x):
    if x < 50000: return '<50K'
    if x < 100000: return '50K-100K'
    if x < 200000: return '100K-200K'
    if x < 300000: return '200K-300K'
    if x < 500000: return '300K-500K'
    return '500K+'
df['credit_limit_band'] = df['credit_limit'].apply(limit_band)

def collections_stage(d):
    if d <= 0: return '1-Current'
    if d <= 2: return '2-Early DPD (1-2mo)'
    if d <= 5: return '3-Mid DPD (3-5mo)'
    return '4-Severe DPD (6mo+)'
df['collections_stage'] = df['current_dpd'].apply(collections_stage)

def risk_band(row):
    score = 0
    score += row['worst_dpd_6mo'] * 10
    score += row['months_delinquent_6mo'] * 5
    score += max(0, (row['credit_utilization'] - 0.8)) * 20
    score += max(0, (0.3 - row['payment_to_bill_ratio'])) * 30
    return round(score, 2)
df['risk_score'] = df.apply(risk_band, axis=1)

def risk_grade(s):
    if s < 5: return 'A - Low Risk'
    if s < 15: return 'B - Moderate Risk'
    if s < 30: return 'C - High Risk'
    return 'D - Severe Risk'
df['risk_grade'] = df['risk_score'].apply(risk_grade)

df['default_flag'] = (df['default'] == 'yes').astype(int)
df['customer_id'] = range(1, len(df) + 1)

education_map = {'grad': 'Graduate School', 'uni': 'University', 'hs': 'High School',
                  'other1': 'Other', 'other2': 'Other', 'other3': 'Other', '0': 'Unknown'}
df['education'] = df['education'].map(education_map)
marital_map = {'married': 'Married', 'single': 'Single', 'other': 'Other', 'na': 'Unknown'}
df['marital_status'] = df['marital_status'].map(marital_map)
df['gender'] = df['gender'].str.capitalize()

cols_order = ['customer_id', 'credit_limit', 'gender', 'education', 'marital_status', 'age', 'age_band',
              'credit_limit_band'] + pay_cols + dpd_cols + \
             ['current_dpd', 'worst_dpd_6mo', 'months_delinquent_6mo', 'avg_dpd_6mo', 'collections_stage'] + \
             bal_cols + pay_amt_cols + \
             ['total_bill_6mo', 'total_paid_6mo', 'payment_to_bill_ratio', 'avg_balance', 'avg_payment',
              'credit_utilization', 'risk_score', 'risk_grade', 'default', 'default_flag']
df = df[cols_order]
df.to_csv('outputs/engineered_dataset.csv', index=False)
print(df.shape)
print(df[['risk_grade', 'default_flag']].groupby('risk_grade').agg(count=('default_flag', 'size'), default_rate=('default_flag', 'mean')))
print(df['collections_stage'].value_counts())
