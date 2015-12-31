/*[[Show histogram. Usage: @@NAME <table_name>[.<partition_name>] <column_name>]]*/
SET FEED OFF
ora _find_object &V1

WITH r AS
 (SELECT /*+materialize*/
   *
  FROM   (SELECT endpoint_number Bucket#,
                 endpoint_value ev,
                 endpoint_actual_value,
                 density,
                 num_nulls,
                 num_distinct,
                 high_value,
                 data_type,
                 a.column_name,
                 NUM_BUCKETS,
                 HISTOGRAM,
                 (c.num_rows - b.num_nulls) / b.sample_size ratio,
                 c.num_rows - b.num_nulls orig_card
          FROM   all_tab_histograms a, All_Tab_Cols b, all_tables c
          WHERE  a.owner = b.owner
          AND    a.table_name = b.table_name
          AND    a.column_name = b.column_name
          AND    a.owner = c.owner
          AND    a.table_name = c.table_name
          AND    a.owner=:object_owner
          AND    a.table_name=:object_name
          AND    upper(a.column_name) = UPPER(:V2)
          AND    :object_subname IS NULL
          UNION ALL
          SELECT bucket_number Bucket#,
                 endpoint_value ev,
                 endpoint_actual_value,
                 density,
                 num_nulls,
                 num_distinct,
                 b.high_value,
                 (SELECT data_type
                  FROM   all_tab_cols c
                  WHERE  a.owner = c.owner
                  AND    a.table_name = c.table_name
                  AND    a.column_name = c.column_name),
                 a.partition_name,
                 NUM_BUCKETS,
                 HISTOGRAM,
                 (c.num_rows - b.num_nulls) / b.sample_size ratio,
                 c.num_rows - b.num_nulls orig_card
          FROM   all_part_histograms a, All_Part_Col_Statistics b, all_tab_partitions c
          WHERE  a.owner = b.owner
          AND    a.table_name = b.table_name
          AND    a.column_name = b.column_name
          AND    a.partition_name = b.partition_name
          AND    a.owner = c.table_owner
          AND    a.table_name = c.table_name
          AND    a.partition_name = c.partition_name
          AND    a.owner=:object_owner
          AND    a.table_name=:object_name
          AND    a.partition_name=:object_subname
          AND    upper(a.column_name) = UPPER(:V2))),
r0 AS
 (SELECT /*+materialize*/ r.*,
         LPAD(to_char(ev, 'fmxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'), LENGTHB(high_value), '0') cv,
         lag(endpoint_actual_value) over(ORDER BY Bucket#) pva,
         Bucket# - lag(Bucket#,1,0) over(ORDER BY Bucket#) buckets,
         lag(LPAD(to_char(ev + CASE
                              WHEN data_type = 'DATE' OR data_type LIKE 'TIMESTAMP' THEN
                               1e-5
                              ELSE
                               1
                          END,
                          'fmxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'),
                  LENGTHB(high_value),
                  '0')) over(ORDER BY Bucket#) pv,
         lag(ev + CASE
                 WHEN data_type = 'DATE' OR data_type LIKE 'TIMESTAMP' THEN
                  1e-5
                 ELSE
                  1
             END) over(ORDER BY Bucket#) opv
  FROM   r),
r1 AS
 (SELECT r0.*,
         NVL(endpoint_actual_value,
             CASE
                 WHEN data_type LIKE '%CHAR%' THEN
                  utl_raw.cast_to_varchar2(cv)
                 WHEN data_type LIKE '%N%CHAR%' THEN
                  to_char(utl_raw.cast_to_nvarchar2(cv))
                 WHEN data_type = 'DATE' OR data_type LIKE 'TIMESTAMP' THEN
                  to_char(to_date(trunc(ev), 'J') + MOD(ev, 1),
                          'YYYY-MM-DD' || DECODE(MOD(ev, 1), 0, '', ' HH24:MI:SS'))
                 WHEN data_type IN ('NUMBER', 'BINARY_DOUBLE', 'BINARY_FLOAT') THEN
                  '' || ev
                 ELSE
                  cv
             END) ep_value,
         NVL(pva,
             CASE
                 WHEN data_type LIKE '%CHAR%' THEN
                  utl_raw.cast_to_varchar2(pv)
                 WHEN data_type LIKE '%N%CHAR%' THEN
                  to_char(utl_raw.cast_to_nvarchar2(pv))
                 WHEN data_type = 'DATE' OR data_type LIKE 'TIMESTAMP' THEN
                  to_char(to_date(trunc(opv), 'J') + MOD(opv, 1),
                          'YYYY-MM-DD' || DECODE(MOD(opv, 1), 0, '', ' HH24:MI:SS'))
                 WHEN data_type IN ('NUMBER', 'BINARY_DOUBLE', 'BINARY_FLOAT') THEN
                  '' || opv
                 ELSE
                  pv
             END) bp_value
  FROM   r0),
r3 AS
 (SELECT (1 - SUM(buckets) / MAX(num_buckets)) / (MAX(num_distinct) - COUNT(1)) new_density
  FROM   r0
  WHERE  buckets > 1)
SELECT column_name,
       Bucket#,
       buckets,
       bp_value,
       ep_value,
       round(decode(HISTOGRAM,
                    'HEIGHT BALANCED',
                    CASE
                        WHEN buckets > 1 THEN
                         buckets / num_buckets * orig_card
                        ELSE
                         orig_card * nvl(new_density,density)
                    END,
                    'FREQUENCY',
                    buckets * ratio),
             2) cardinality
FROM   r1, r3;
