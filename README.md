# Performance comparison of MySQL vs. Postgres with HammerDb on an I/O-bound workload with SERIALIZABLE isolation level

I/O-bound workload = RAM << data size. MySQL 8.0.26. Postgres 14.5. Postgres is also referred to as Pg for short.

## Results

From HammerDb [docs](https://www.hammerdb.com/docs/ch03s04.html):

>As such NOPM (New Orders per minute) as a performance metric independent of any particular database implementation is the recommended primary metric to use.

### NOPM

| Virtual Users (threads) | MySQL | Pg 1 | Pg 2 | Pg 3 |
| --- | ---- | ---- | ---- | ---- |
| 1 | 183 | 418 | - | - |
| 10 | 1688 | x | 2779 | 2602 |
| 100 | 2335 | x | 2891 | 2736 |

MySQL gave me no issues but with Pg, I had to try 3 times.
The first attempt with Pg (`pg_raiseerror=false`) ended up with some unsuccessful runs. `x` = unsuccessful run.
First I received a `out of shared memory` error that I fixed by setting `max_pred_locks_per_transaction` and `max_locks_per_transaction` from `64` to `128`.
After that when run with `10` virtual users, an `invalid transaction termination`
was observed in server logs which is displayed as `Vuser 9:New Order Procedure Error set RAISEERROR for Details` for example by HammerDb.
I gave up and could not investigate more. The test with `100` users was aborted. The test with `10` users was allowed to run but it
did not terminate after the `30` minute duration. Server kept on showing running queries. Ultimately it was aborted.

[MySQL query snapshot](mysql_snapshot.txt) running with 100 vu.

[Pg query snapshot](pg_snapshot.txt) running with 1 vu.

The second attempt was done with `pg_raiseerror=true`. With this setting the threads that receive an error are aborted and thus the contention
(concurrency) goes down. The third attempt was done with same config as the first attempt, namely that `pg_raiseerror=false` and this time I did not get
unusable runs although there were many serialization errors and `invalid transaction termination`.
MySQL is with `raiseerror=false` as I believe that is the _right_ setting to simulate a _sustained_ concurrent load and to _judge_ the performance against.
From the [docs](https://www.hammerdb.com/docs/ch04s06.html):

>If set to TRUE on detecting an error the user will report the error into the HammerDB console and then terminate execution. If set to FALSE the virtual user will ignore the error and proceed with executing the next transaction.

_I don't know if HammerDb discounts transactions that return with an error. If its counting unsuccessful transactions in its NOPM count, that is a bug._

### TPM

| Virtual Users | MySQL | Pg 1 | Pg 2 | Pg 3 |
| --- | ---- | ---- | ---- | ---- |
| 1 | 418 | 1230 | - | - |
| 10 | 3913 | x | 6611 | 6190 |
| 100 | 5432 | x | 6888 | 6717 |

### CPU Utilization

| Virtual Users | MySQL | Pg 1 | Pg 2 | Pg 3 |
| --- | ---- | ---- | ---- | ---- |
| 1 | 15% | 18% | - | - |
| 10 | 64% | x | 71% | 71% |
| 100 | 100% | x | 40% | 100% |

Note on Pg 2: With `100` users Pg starts out with `100%` CPU Utilization but the failures cause vu threads to abort which eventually leads to drop in CPU Utilization.

## Methodology

Pre-built [Docker](https://hub.docker.com/r/tpcorg/hammerdb) image of HammerDb version 4.7 was used.

```
docker run --network=host -it --name hammerdb hammerdb bash
```

 `buildschema` generated schema with `400` warehouses and `100` virtual users
(time taken = `30` min on both MySQL and Pg). This resulted in following data sizes on MySQL and Postgres. Roughly `38GB` of data was generated across
 `9` tables and totalling approximately `200M` rows (~`200` bytes/row). To simulate an _I/O-bound_ workload, both MySQL and Postgres
servers were provisioned with `3.75GB` RAM and `1` vCPU with SSD storage. Tests were run for `30` minutes each and the transaction isolation level
was set to `SERIALIZABLE` as that is what was of interest to me. In his [video](https://www.youtube.com/watch?v=PAktFHBT_QU) Steve Shaw specifically
states he does not do any concurrency control whatever in HammerDb; a design choice he has made.

MySQL:

```
mysql> show tables;
+--------------------+
| Tables_in_hammerdb |
+--------------------+
| customer           |
| district           |
| history            |
| item               |
| new_order          |
| order_line         |
| orders             |
| stock              |
| warehouse          |
+--------------------+
9 rows in set (0.04 sec)

mysql> SELECT SUM(data_length + index_length) / 1024 / 1024 AS 'DB Size (MB)' FROM information_schema.tables WHERE table_schema = 'hammerdb';
+----------------+
| DB Size (MB)   |
+----------------+
| 35,431.82812500 |
+----------------+
1 row in set (0.04 sec)

mysql> SELECT SUM(data_length) / 1024 / 1024 AS 'DB Size (MB)' FROM information_schema.tables WHERE table_schema = 'hammerdb';
+----------------+
| DB Size (MB)   |
+----------------+
| 34,074.82812500 |
+----------------+
1 row in set (0.05 sec)
```

Postgres:

```
hammerdb=> select relname, n_tup_ins - n_tup_del as rowcount from pg_stat_user_tables;
  relname   | rowcount
------------+-----------
 district   |      4000
 order_line | 119,324,502
 orders     |  11,933,700
 item       |    100,000
 stock      |  40,000,000
 customer   |  11,953,000
 new_order  |   3,573,700
 history    |  11,953,000
 warehouse  |       400
(9 rows)

hammerdb=> SELECT pg_size_pretty(pg_database_size('hammerdb'));
 pg_size_pretty
----------------
 38 GB
(1 row)
```

## Configuration

### HammerDb MySQL Configuration

[print dict](hammerdb_mysql_dict.txt)

[print vuconf](hammerdb_mysql_vuconf.txt) for the test with `10` vu

### HammerDb Pg Configuration

[print dict](hammerdb_pg_dict.txt)

[print vuconf](hammerdb_pg_vuconf.txt) for the test with `10` vu

### MySQL Server Configuration

Of note are `innodb_buffer_pool_size=1,476,395,008`.

```
mysql -h x.x.x.x -u hammerdb -p -e "show variables" > mysql-settings.txt
```

[mysql-settings.txt](mysql-settings.txt)

### Pg Server Configuration

Of note are `effective_cache_size=2000000kB`, `shared_buffers=1226MB`.

```
hammerdb=> \o pg-settings.txt
hammerdb=> select name, setting from pg_settings;
hammerdb=> \o
```

[pg-settings.txt](pg-settings.txt)

### MySQL Execution Script

The [script](hammerdb_mysql_test_script.tcl) that runs the perf test.

### Pg Execution Script

The [script](hammerdb_pg_test_script.tcl) that runs the perf test.

## Appendix

### Running Pg with `pg_raiseerror=true`

After first unsuccessful attempt with Pg, I then re-ran Pg tests but this time I set `pg_raiseerror=true`.
This time I was able to get better luck with Pg and got following numbers:

10vu: there was one vu that got aborted with `invalid transaction termination` exception.

```
Vuser 1:TEST RESULT : System achieved 2779 NOPM from 6611 PostgreSQL TPM
```

100vu: many vus got aborted with exceptions. See [log](hammerdb_pg_100vu.txt) file.

```
Vuser 1:TEST RESULT : System achieved 2891 NOPM from 6888 PostgreSQL TPM
```

I also had to set `max_connections=200` on Pg server (earlier it was `100`).

### Observations with `pg_raiseerror=true`

Many Pg users (threads) got aborted like this when running with 100vu:

```
Error in Virtual User 30: ERROR:  could not serialize access due to read/write dependencies among transactions
DETAIL:  Reason code: Canceled on conflict out to pivot 6214880, during read.
HINT:  The transaction might succeed if retried.

Vuser 30:FINISHED FAILED
```

In Pg, these failures are _expected_ to happen due to serialization conflicts and the transaction should be _re-tried_.
That is how SSI (serialization snapshot isolation) works. But with `raiseerror=true` HammerDb aborts the vu whereas with `raiseerror=false`
I couldn't get a successful run. The aborting of users actually helped Pg (vs. MySQL) here because it reduced the contention and that _improves_ the
throughput. Refer Steve Shaw's [video](https://youtu.be/PAktFHBT_QU?t=2695) where he shows a graph of this phenomenon.

In case of MySQL, it handles concurrency using a combination of 2PL and MVCC. Sometimes conflicting transactions get blocked which is a sign of locking.
At other times it raises a deadlock error. In this study a deadlock error presumably never happened as I never saw any failure in HammerDb output
when running MySQL. Refer [log](hammerdb_mysql_100vu.txt)

Below is how HammerDb is handling `RAISEERROR`. Refer [source](hammerdb_pg_test_script.tcl):

```
if {[pg_result $result -status] != "PGRES_TUPLES_OK"} {
    if { $RAISEERROR } {
        error "[pg_result $result -error]"
    } else {
        puts "New Order Procedure Error set RAISEERROR for Details"
    }
    pg_result $result -clear
} else {
    pg_result $result -clear
}
```

### Thoughts

SSI (implemented in Pg) is believed by some to be superior to 2PL method of implementing serializable transaction isolation
(2PL is what MySQL is using for serializable transaction isolation) because SSI implements optimistic concurrency control where concurrent transactions do
not block each other. Thinking from purely _theoretical_ perspective, I feel SSI should outperform 2PL when the contention is not too high and transactions
are short. If the contention is high and transactions are long lived, then SSI should give _worse_ performance than 2PL because with SSI, the database will
end up executing many CPU instructions that will not lead to any useful work whereas with 2PL, the conflicting transactions will wait for their turn and
CPU resources will not be wasted on work that gets thrown away. The downside of locks is that they are risky. Bugs happen in the code and if there is a
lock placed erroneously it can be devastating and catastrophic.

### Debugging Notes

[pg sprocs](https://github.com/TPC-Council/HammerDB/blob/master/src/postgresql/pgoltp.tcl)

[tpcccommon](https://github.com/TPC-Council/HammerDB/blob/master/modules/tpcccommon-1.0.tm)

As I had suspected, [pgoltp.tcl](https://github.com/TPC-Council/HammerDB/blob/master/src/postgresql/pgoltp.tcl#L2319):

```
set choice [ RandomNumber 1 23 ]
            if {$choice <= 10} {
                puts "new order"
                if { $KEYANDTHINK } { keytime 18 }
                set curn_no [ pick_cursor $neworder_policy [ join $neworder_cursors ] $nocnt $nolen ]
                set cursor_position [ lsearch $neworder_cursors $curn_no ]
                set lda_no [ lindex [ join $csneworder ] $cursor_position ]
                neword $lda_no $w_id $w_id_input $RAISEERROR $ora_compatible $pg_storedprocs
                incr nocnt
```

the NOPM counter is incremented irrespective of whether the call to `neword` was successful or not. So in that case
all the results are meaningless and this tool is of no use. It will always favor Pg over MySQL irrespective of whether
`RAISEERROR` is `true` or `false`. When `RAISEERROR` is `true`, Pg threads will get aborted whereas MySQL will
continue to get hammered by many more threads and when `RAISEERROR` is `false`, even if the call to `neword` fails,
HammerDB will keep on merrily incrementing NOPM count.

Hold on, it gets better. Above is not the code that is computing NOPM. I [modified](pgoltp.tcl) the code so that `neword` returns a `success` or `error`
and based on that increment the `nocnt` but it did not change the NOPM count. I still got `2870` NOPM with `100` vu.
The code that is computing NOPM is like this I believe:

[Line 2905](https://github.com/TPC-Council/HammerDB/blob/master/src/postgresql/pgoltp.tcl#L2905) or
[Line 96](hammerdb_pg_test_script.tcl#L96):

```
pg_select $lda1 "select sum(d_next_o_id) from district" o_id_arr {
    set start_nopm $o_id_arr(sum)
}
```

[Line 2944](https://github.com/TPC-Council/HammerDB/blob/master/src/postgresql/pgoltp.tcl#L2944) or
[Line 135](hammerdb_pg_test_script.tcl#L135):

```
pg_select $lda1 "select sum(d_next_o_id) from district" o_id_arr {
    set end_nopm $o_id_arr(sum)
}
set tpm [ expr {($end_trans - $start_trans)/$durmin} ]
set nopm [ expr {($end_nopm - $start_nopm)/$durmin} ]
```

I am not sure if this logic is correct:

1. Why is he taking the `d_next_o_id` of `district` to calculate count of new orders?
2. Why is he summing the `d_next_o_id` column (which is not a `0`, `1` column) to get the count?

I think I understand now. Each district is filling orders independently so each district has its own next new order id counter which is
`d_next_o_id`. But the sum of `d_next_o_id` does not match with the row count of `new_order` table.

```
hammerdb=> \d district
                       Table "public.district"
   Column    |         Type          | Collation | Nullable | Default
-------------+-----------------------+-----------+----------+---------
 d_w_id      | integer               |           | not null |
 d_next_o_id | integer               |           | not null |
 d_id        | smallint              |           | not null |
 d_ytd       | numeric(12,2)         |           | not null |
 d_tax       | numeric(4,4)          |           | not null |
 d_name      | character varying(10) |           | not null |
 d_street_1  | character varying(20) |           | not null |
 d_street_2  | character varying(20) |           | not null |
 d_city      | character varying(20) |           | not null |
 d_state     | character(2)          |           | not null |
 d_zip       | character(9)          |           | not null |
Indexes:
    "district_i1" PRIMARY KEY, btree (d_w_id, d_id)
```

```
hammerdb=> select d_next_o_id from district limit 10;
 d_next_o_id
-------------
        3207
        3183
        3239
        3228
        3201
        3209
        3217
        3195
        3188
        3207
(10 rows)
```

```
hammerdb=> select count(*) from new_order;
  count
---------
 3,591,798
(1 row)

hammerdb=> select sum(d_next_o_id) from district;
   sum
----------
 12,932,708
(1 row)
```