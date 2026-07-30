CREATE DATABASE ireland_cpi_db;
USE ireland_cpi_db;

CREATE TABLE staging_cpi_raw (
    staging_id INT AUTO_INCREMENT PRIMARY KEY,
    source_system VARCHAR(50) DEFAULT 'CSO_CPM20',
    statistic_label VARCHAR(200),
    commodity_group VARCHAR(150),
    month_year_text VARCHAR(20),
    unit VARCHAR(50),
    value_text VARCHAR(50),
    loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

 
 SET GLOBAL local_infile = 1;
 
SHOW GLOBAL VARIABLES LIKE 'local_infile';

TRUNCATE TABLE staging_cpi_raw;

LOAD DATA LOCAL INFILE 'C:/Users/DELL/Downloads/cpi_cpm20_raw.csv.csv'
INTO TABLE staging_cpi_raw
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ','
ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 ROWS
(
    statistic_label,
    month_year_text,
    commodity_group,
    unit,
    value_text
);

SELECT COUNT(*) AS total_rows FROM staging_cpi_raw;

SELECT DISTINCT statistic_label FROM staging_cpi_raw;

SELECT * FROM staging_cpi_raw LIMIT 5;

 
 USE ireland_cpi_db;

CREATE TABLE dim_date (
    date_id INT AUTO_INCREMENT PRIMARY KEY,
    full_date DATE,
    month_num TINYINT,
    month_name VARCHAR(20),
    quarter TINYINT,
    year SMALLINT,
    is_year_start BOOLEAN,
    UNIQUE (full_date)
);

CREATE TABLE dim_commodity_group (
    group_id INT AUTO_INCREMENT PRIMARY KEY,
    group_name VARCHAR(150) UNIQUE,
    group_category ENUM('Food','Housing','Transport','Clothing',
      'Health','Education','Recreation','Communications',
      'Restaurants','Miscellaneous','Alcohol_Tobacco',
      'Furnishings','Other')
);

INSERT INTO dim_commodity_group (group_name, group_category) VALUES
('All Items', 'Other'),
('Food and non-alcoholic beverages', 'Food'),
('Alcoholic beverages, tobacco and narcotics', 'Alcohol_Tobacco'),
('Clothing and footwear', 'Clothing'),
('Housing, water, electricity, gas and other fuels', 'Housing'),
('Furnishings, household equipment and routine household maintenance', 'Furnishings'),
('Health', 'Health'),
('Transport', 'Transport'),
('Information and communication', 'Communications'),
('Recreation, sport and culture', 'Recreation'),
('Education services', 'Education'),
('Restaurants and accommodation services', 'Restaurants'),
('Insurance and financial services', 'Miscellaneous'),
('Personal care, social protection and miscellaneous goods and services', 'Miscellaneous');

SELECT * FROM dim_commodity_group;

INSERT INTO dim_date (full_date, month_num, month_name, quarter, year, is_year_start)
SELECT DISTINCT
    STR_TO_DATE(CONCAT(month_year_text, ' 01'), '%Y %M %d') AS full_date,
    MONTH(STR_TO_DATE(CONCAT(month_year_text, ' 01'), '%Y %M %d')) AS month_num,
    MONTHNAME(STR_TO_DATE(CONCAT(month_year_text, ' 01'), '%Y %M %d')) AS month_name,
    QUARTER(STR_TO_DATE(CONCAT(month_year_text, ' 01'), '%Y %M %d')) AS quarter,
    YEAR(STR_TO_DATE(CONCAT(month_year_text, ' 01'), '%Y %M %d')) AS year,
    CASE WHEN MONTH(STR_TO_DATE(CONCAT(month_year_text, ' 01'), '%Y %M %d')) = 1 THEN TRUE ELSE FALSE END AS is_year_start
FROM staging_cpi_raw
WHERE month_year_text IS NOT NULL;

SELECT COUNT(*) AS total_dates FROM dim_date;
SELECT * FROM dim_date ORDER BY full_date LIMIT 5;
SELECT * FROM dim_date ORDER BY full_date DESC LIMIT 5;

USE ireland_cpi_db;

CREATE TABLE etl_load_log (
    log_id INT AUTO_INCREMENT PRIMARY KEY,
    load_type ENUM('FULL','INCREMENTAL'),
    rows_inserted INT DEFAULT 0,
    rows_updated INT DEFAULT 0,
    status ENUM('SUCCESS','FAILED','PARTIAL'),
    started_at TIMESTAMP,
    completed_at TIMESTAMP,
    error_message VARCHAR(500)
);

CREATE TABLE fact_cpi (
    record_id INT AUTO_INCREMENT PRIMARY KEY,
    batch_id INT NOT NULL,
    date_id INT,
    group_id INT,
    index_value DECIMAL(10,2) CHECK (index_value >= 0),
    mom_change DECIMAL(6,2),
    yoy_change DECIMAL(6,2),
    load_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (date_id) REFERENCES dim_date(date_id),
    FOREIGN KEY (group_id) REFERENCES dim_commodity_group(group_id),
    FOREIGN KEY (batch_id) REFERENCES etl_load_log(log_id),
    UNIQUE (date_id, group_id)
);

USE ireland_cpi_db;

DELIMITER $$

CREATE PROCEDURE sp_load_fact_from_staging()
BEGIN
    DECLARE current_batch_id INT;
    DECLARE v_rows_inserted INT DEFAULT 0;
    DECLARE done INT DEFAULT FALSE;
    DECLARE v_group_name VARCHAR(150);
    DECLARE grp_cursor CURSOR FOR
        SELECT DISTINCT commodity_group FROM staging_cpi_raw;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        UPDATE etl_load_log
        SET status = 'FAILED',
            error_message = 'SQL exception during load',
            completed_at = NOW()
        WHERE log_id = current_batch_id;
    END;

    -- Step 1: log that a load has started
    INSERT INTO etl_load_log (load_type, status, started_at)
    VALUES ('FULL', 'PARTIAL', NOW());
    SET current_batch_id = LAST_INSERT_ID();

    START TRANSACTION;

    -- Step 2: loop through each commodity group (demonstrates CURSOR usage)
    OPEN grp_cursor;
    read_loop: LOOP
        FETCH grp_cursor INTO v_group_name;
        IF done THEN
            LEAVE read_loop;
        END IF;

        INSERT INTO fact_cpi (batch_id, date_id, group_id, index_value)
        SELECT
            current_batch_id,
            d.date_id,
            g.group_id,
            CAST(s.value_text AS DECIMAL(10,2))
        FROM staging_cpi_raw s
        JOIN dim_commodity_group g ON g.group_name = s.commodity_group
        JOIN dim_date d ON d.full_date = STR_TO_DATE(CONCAT(s.month_year_text, ' 01'), '%Y %M %d')
        WHERE s.statistic_label = 'Consumer Price Index (Base Month December 2023 = 100)'
          AND s.commodity_group = v_group_name
          AND s.value_text REGEXP '^[0-9]+(\\.[0-9]+)?$'
          AND NOT EXISTS (
              SELECT 1 FROM fact_cpi f
              WHERE f.date_id = d.date_id AND f.group_id = g.group_id
          );

        SET v_rows_inserted = v_rows_inserted + ROW_COUNT();
    END LOOP;
    CLOSE grp_cursor;

    -- Step 3: mark the load as successful
    UPDATE etl_load_log
    SET status = 'SUCCESS',
        rows_inserted = v_rows_inserted,
        completed_at = NOW()
    WHERE log_id = current_batch_id;

    COMMIT;
END$$

DELIMITER ;

CALL sp_load_fact_from_staging();

SELECT * FROM etl_load_log;
SELECT COUNT(*) FROM fact_cpi;
SELECT * FROM fact_cpi LIMIT 10;


DELIMITER $$

CREATE PROCEDURE sp_calculate_mom_yoy_changes()
BEGIN
    START TRANSACTION;

    UPDATE fact_cpi f
    JOIN (
        SELECT
            record_id,
            ROUND(
                (index_value - LAG(index_value, 1) OVER (PARTITION BY group_id ORDER BY date_id))
                / LAG(index_value, 1) OVER (PARTITION BY group_id ORDER BY date_id) * 100
            , 2) AS calc_mom,
            ROUND(
                (index_value - LAG(index_value, 12) OVER (PARTITION BY group_id ORDER BY date_id))
                / LAG(index_value, 12) OVER (PARTITION BY group_id ORDER BY date_id) * 100
            , 2) AS calc_yoy
        FROM fact_cpi
    ) calc ON calc.record_id = f.record_id
    SET f.mom_change = calc.calc_mom,
        f.yoy_change = calc.calc_yoy;

    COMMIT;
END$$

DELIMITER ;

CALL sp_calculate_mom_yoy_changes();

SELECT
    f.record_id,
    d.full_date,
    g.group_name,
    f.index_value,
    f.mom_change,
    f.yoy_change
FROM fact_cpi f
JOIN dim_date d
    ON f.date_id = d.date_id
JOIN dim_commodity_group g
    ON f.group_id = g.group_id
ORDER BY g.group_name, d.full_date
LIMIT 30;

SELECT * FROM fact_cpi WHERE group_id = 1 ORDER BY date_id LIMIT 20;

SELECT record_id, date_id, group_id, index_value, mom_change, yoy_change
FROM fact_cpi
WHERE group_id = 1
ORDER BY date_id
LIMIT 20 OFFSET 12;

DELIMITER $$

CREATE FUNCTION fn_classify_inflation_level(p_yoy_change DECIMAL(6,2))
RETURNS VARCHAR(20)
DETERMINISTIC
BEGIN
    DECLARE result VARCHAR(20);
    IF p_yoy_change IS NULL THEN
        SET result = 'No Data';
    ELSEIF p_yoy_change < 0 THEN
        SET result = 'Deflation';
    ELSEIF p_yoy_change <= 2 THEN
        SET result = 'Low';
    ELSEIF p_yoy_change <= 5 THEN
        SET result = 'Moderate';
    ELSE
        SET result = 'High';
    END IF;
    RETURN result;
END$$

DELIMITER ;
SELECT fn_classify_inflation_level(4.2) AS test1;
SELECT fn_classify_inflation_level(-1.5) AS test2;


DELIMITER $$

CREATE TRIGGER trg_before_insert_fact_cpi
BEFORE INSERT ON fact_cpi
FOR EACH ROW
BEGIN
    IF NEW.index_value < 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Index value cannot be negative';
    END IF;
END$$

DELIMITER ;

INSERT INTO fact_cpi (batch_id, date_id, group_id, index_value)
VALUES (1, 1, 1, -50);

CREATE TABLE agg_cpi_monthly (
    date_id INT,
    group_id INT,
    index_value DECIMAL(10,2),
    mom_change DECIMAL(6,2),
    yoy_change DECIMAL(6,2),
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (date_id, group_id)
);

DELIMITER $$

CREATE TRIGGER trg_after_insert_fact_cpi
AFTER INSERT ON fact_cpi
FOR EACH ROW
BEGIN
    INSERT INTO agg_cpi_monthly (date_id, group_id, index_value, mom_change, yoy_change)
    VALUES (NEW.date_id, NEW.group_id, NEW.index_value, NEW.mom_change, NEW.yoy_change)
    ON DUPLICATE KEY UPDATE
        index_value = NEW.index_value,
        mom_change = NEW.mom_change,
        yoy_change = NEW.yoy_change,
        last_updated = NOW();
END$$

DELIMITER ;

SELECT COUNT(*) FROM agg_cpi_monthly;

INSERT INTO agg_cpi_monthly (date_id, group_id, index_value, mom_change, yoy_change)
SELECT date_id, group_id, index_value, mom_change, yoy_change
FROM fact_cpi
ON DUPLICATE KEY UPDATE
    index_value = VALUES(index_value),
    mom_change = VALUES(mom_change),
    yoy_change = VALUES(yoy_change),
    last_updated = NOW();
    
    SELECT COUNT(*) FROM agg_cpi_monthly;
    
    
INSERT INTO dim_date (full_date, month_num, month_name, quarter, year, is_year_start)
VALUES ('2026-07-01', 7, 'July', 3, 2026, FALSE);

SELECT date_id FROM dim_date WHERE full_date = '2026-07-01';

INSERT INTO fact_cpi (batch_id, date_id, group_id, index_value)
VALUES (1, 512, 1, 130.50);


SELECT * FROM agg_cpi_monthly WHERE date_id = 512 AND group_id = 1;


USE ireland_cpi_db;

DELIMITER $$

CREATE PROCEDURE sp_get_cpi_trend(
    IN p_group_name VARCHAR(150),
    IN p_start_date DATE,
    IN p_end_date DATE
)
BEGIN
    SELECT
        d.full_date,
        g.group_name,
        f.index_value,
        f.mom_change,
        f.yoy_change
    FROM fact_cpi f
    JOIN dim_date d ON f.date_id = d.date_id
    JOIN dim_commodity_group g ON f.group_id = g.group_id
    WHERE g.group_name = p_group_name
      AND d.full_date BETWEEN p_start_date AND p_end_date
    ORDER BY d.full_date;
END$$

DELIMITER ;

CALL sp_get_cpi_trend('Food and non-alcoholic beverages', '2020-01-01', '2024-12-31');

DELIMITER $$

CREATE PROCEDURE sp_get_high_inflation_alert(
    IN p_year INT
)
BEGIN
    SET @threshold_yoy_alert = 5.0;

    SELECT
        g.group_name,
        d.full_date,
        f.yoy_change
    FROM fact_cpi f
    JOIN dim_date d ON f.date_id = d.date_id
    JOIN dim_commodity_group g ON f.group_id = g.group_id
    WHERE d.year = p_year
      AND f.yoy_change > @threshold_yoy_alert
    ORDER BY f.yoy_change DESC;
END$$

DELIMITER ;

CALL sp_get_high_inflation_alert(2022);

SHOW VARIABLES LIKE 'event_scheduler';

USE ireland_cpi_db;

DELIMITER $$

CREATE EVENT evt_monthly_yoy_recalc
ON SCHEDULE EVERY 1 MONTH
STARTS CURRENT_TIMESTAMP
DO
BEGIN
    CALL sp_calculate_mom_yoy_changes();
END$$

DELIMITER ;


DELIMITER $$

CREATE EVENT evt_purge_old_logs
ON SCHEDULE EVERY 1 WEEK
STARTS CURRENT_TIMESTAMP
DO
BEGIN
    DELETE FROM etl_load_log
    WHERE completed_at < DATE_SUB(NOW(), INTERVAL 6 MONTH);
END$$

DELIMITER ;

SHOW EVENTS;


USE ireland_cpi_db;

CREATE VIEW vw_cpi_monthly_summary AS
SELECT
    d.full_date,
    d.year,
    d.quarter,
    d.month_name,
    g.group_name,
    g.group_category,
    f.index_value,
    f.mom_change,
    f.yoy_change,
    fn_classify_inflation_level(f.yoy_change) AS inflation_level
FROM fact_cpi f
JOIN dim_date d ON f.date_id = d.date_id
JOIN dim_commodity_group g ON f.group_id = g.group_id;

CREATE VIEW vw_inflation_alerts AS
SELECT
    d.full_date,
    g.group_name,
    f.yoy_change
FROM fact_cpi f
JOIN dim_date d ON f.date_id = d.date_id
JOIN dim_commodity_group g ON f.group_id = g.group_id
WHERE f.yoy_change > 5.0
ORDER BY f.yoy_change DESC;

SELECT * FROM vw_cpi_monthly_summary LIMIT 10;
SELECT * FROM vw_inflation_alerts LIMIT 10;

EXPLAIN SELECT * FROM fact_cpi WHERE group_id = 5 AND date_id BETWEEN 300 AND 350;

USE ireland_cpi_db;

CREATE INDEX idx_fact_group_date ON fact_cpi(group_id, date_id);

EXPLAIN SELECT * FROM fact_cpi WHERE group_id = 5 AND date_id BETWEEN 300 AND 350;

SHOW TABLES;
SHOW EVENTS;
SELECT COUNT(*) FROM fact_cpi;
SELECT COUNT(*) FROM agg_cpi_monthly;

USE ireland_cpi_db;

DELETE FROM fact_cpi WHERE date_id = 512 AND group_id = 1;

DELETE FROM agg_cpi_monthly WHERE date_id = 512 AND group_id = 1;

DELETE FROM dim_date WHERE date_id = 512;

SELECT COUNT(*) FROM fact_cpi;
SELECT COUNT(*) FROM agg_cpi_monthly;