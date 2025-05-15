USE AlcoholUseAnalysis;
-- 1.1: Create a staging table for raw BRFSS responses
CREATE TABLE Stg_BRFSS_OK (
  Question           TEXT,        -- the survey question text
  Response           VARCHAR(20), -- the participant’s answer (e.g. 'Yes' or 'No')
  Break_Out          VARCHAR(50), -- the demographic value (e.g. '18-24', 'Male', etc.)
  Break_Out_Category VARCHAR(50), -- the type of breakout (e.g. 'Age Group' or 'Gender')
  Sample_Size        INT,         -- total people asked
  Data_Value         INT,         -- number who answered “Yes”
  ZipCode            INT          -- respondent’s ZIP code
);

-- 1.2: Create a staging table for ZIP→City→County lookup
CREATE TABLE Stg_Location_OK (
  ZipCode INT,              -- 5-digit ZIP code
  City    VARCHAR(100),     -- city name
  County  VARCHAR(100)      -- county name
);

-- Checking that the staging tables loaded correctly after bulk-import CSVs:
SELECT COUNT(*) AS brfss_rows FROM Stg_BRFSS_OK;    -- expect ~667 rows
SELECT COUNT(*) AS loc_rows   FROM Stg_Location_OK; -- expect one row per OK ZIP

-- 2.1: Build the location dimension
CREATE TABLE Dim_Location (
  ZipCode INT PRIMARY KEY,   -- surrogate = actual ZIP code
  City    VARCHAR(100),
  County  VARCHAR(100),
  State   VARCHAR(50)        -- will always be 'Oklahoma'
);

INSERT INTO Dim_Location (ZipCode, City, County, State)
SELECT DISTINCT
       ZipCode,
       City,
       County,
       'Oklahoma' AS State
  FROM Stg_Location_OK;


-- 2.2: Build the questions dimension
CREATE TABLE Dim_Questions (
  QuestionID   INT AUTO_INCREMENT PRIMARY KEY, -- surrogate key
  QuestionText TEXT,                           -- the question string
  ResponseType VARCHAR(20)                     -- e.g. 'Yes/No'
);

INSERT INTO Dim_Questions (QuestionText, ResponseType)
SELECT DISTINCT
       Question,
       'Yes/No'
  FROM Stg_BRFSS_OK;
  
  
  -- 2.3: Build the demographics dimension (only age groups & gender)
CREATE TABLE Dim_Demographics (
  DemographicID      INT AUTO_INCREMENT PRIMARY KEY, -- surrogate key
  Break_Out          VARCHAR(50),    -- e.g. '18-24', 'Male'
  Break_Out_Category VARCHAR(50)     -- e.g. 'Age Group', 'Gender'
);

INSERT INTO Dim_Demographics (Break_Out, Break_Out_Category)
SELECT DISTINCT
       Break_Out,
       Break_Out_Category
  FROM Stg_BRFSS_OK
 WHERE Break_Out_Category IN ('Age Group','Gender');


-- 2.4: Build a static date dimension for Q1 2009
CREATE TABLE Dim_Date (
  Date_ID INT PRIMARY KEY,  -- surrogate in YYYYMM format
  Year    INT,
  Quarter TINYINT,
  Month   TINYINT
);

INSERT INTO Dim_Date (Date_ID, Year, Quarter, Month)
VALUES (200901, 2009, 1, 1);  -- Q1 of 2009


-- Validate dimension row counts
SELECT COUNT(*) FROM Dim_Location;   -- should = loc_rows
SELECT COUNT(*) FROM Dim_Questions;  -- distinct questions
SELECT COUNT(*) FROM Dim_Demographics; -- distinct (age+gender) combos
SELECT COUNT(*) FROM Dim_Date;       -- =1


-- 3.1: Create the fact table
CREATE TABLE Fact_SurveyResponses (
  ResponseID     INT AUTO_INCREMENT PRIMARY KEY,  -- surrogate key
  ZipCode        INT,                             -- FK → Dim_Location
  DemographicID  INT,                             -- FK → Dim_Demographics
  QuestionID     INT,                             -- FK → Dim_Questions
  Date_ID        INT,                             -- FK → Dim_Date
  Sample_Size    INT,                             -- fact measure
  Data_Value     INT,                             -- fact measure
  FOREIGN KEY (ZipCode)       REFERENCES Dim_Location(ZipCode),
  FOREIGN KEY (DemographicID) REFERENCES Dim_Demographics(DemographicID),
  FOREIGN KEY (QuestionID)    REFERENCES Dim_Questions(QuestionID),
  FOREIGN KEY (Date_ID)       REFERENCES Dim_Date(Date_ID)
);


-- 3.2: Load both the 18–24 age group and gender rows into the fact
INSERT INTO Fact_SurveyResponses
  (ZipCode, DemographicID, QuestionID, Date_ID, Sample_Size, Data_Value)
SELECT
  b.ZipCode,
  d.DemographicID,
  q.QuestionID,
  200901,              -- static Date_ID for Q1 2009
  b.Sample_Size,
  b.Data_Value
FROM Stg_BRFSS_OK AS b
JOIN Dim_Demographics d
  ON b.Break_Out = d.Break_Out
 AND b.Break_Out_Category = d.Break_Out_Category
JOIN Dim_Questions q
  ON b.Question = q.QuestionText
WHERE
     b.Response           = 'Yes'                                -- only “Yes” answers
 AND b.Break_Out_Category IN ('Age Group','Gender')            -- only age & gender rows
 AND (
      (b.Break_Out_Category='Age Group' AND b.Break_Out='18-24')
   OR (b.Break_Out_Category='Gender')
     )
 AND b.Data_Value IS NOT NULL;                                 -- drop nulls
  
  
  -- 3.3: Sanity-check row counts
SELECT COUNT(*) AS staging_18_24_yes
  FROM Stg_BRFSS_OK
 WHERE Response           = 'Yes'
   AND Break_Out_Category = 'Age Group'
   AND Break_Out          = '18-24';

SELECT COUNT(*) AS fact_rows
  FROM Fact_SurveyResponses;
  
  
  
  -- 4.1: County-level % of heavy-drinkers among 18–24
SELECT
  l.County,
  SUM(f.Sample_Size)                     AS Total_Sample,
  SUM(f.Data_Value)                      AS Total_Yes,
  ROUND(SUM(f.Data_Value) / SUM(f.Sample_Size) * 100, 2)
    AS Percent_Yes
FROM Fact_SurveyResponses f
JOIN Dim_Location     l ON f.ZipCode      = l.ZipCode
JOIN Dim_Demographics d ON f.DemographicID= d.DemographicID
WHERE d.Break_Out = '18-24'
GROUP BY l.County
ORDER BY Percent_Yes DESC;


-- 4.2: City-level % of heavy-drinkers among 18–24
SELECT
  l.City,
  ROUND(SUM(f.Data_Value) / SUM(f.Sample_Size) * 100, 2)
    AS Percent_Yes
FROM Fact_SurveyResponses f
JOIN Dim_Location     l ON f.ZipCode      = l.ZipCode
JOIN Dim_Demographics d ON f.DemographicID= d.DemographicID
WHERE d.Break_Out = '18-24'
GROUP BY l.City
ORDER BY Percent_Yes DESC;


-- 4.3: Gender breakdown of heavy-drinking among all loaded (including age & gender) A method to identify groups of adolescents who may be at highest risk for alcohol abuse.
SELECT
  d.Break_Out       AS Gender,
  SUM(f.Data_Value)   AS Total_Yes,
  SUM(f.Sample_Size)  AS Total_Sample,
  ROUND(SUM(f.Data_Value) / SUM(f.Sample_Size) * 100, 2)
    AS Percent_Yes
FROM Fact_SurveyResponses f
JOIN Dim_Demographics d
  ON f.DemographicID = d.DemographicID
WHERE d.Break_Out_Category = 'Gender'      -- only gender rows
GROUP BY d.Break_Out
ORDER BY Percent_Yes DESC;





