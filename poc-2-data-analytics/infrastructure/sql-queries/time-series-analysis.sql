-- Query for time series analysis by hour
SELECT 
    datehour,
    COUNT(*) as view_count
FROM 
    my_ingested_data
GROUP BY 
    datehour
ORDER BY 
    datehour ASC;
