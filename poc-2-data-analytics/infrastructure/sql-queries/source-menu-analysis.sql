-- Query for source menu analysis
SELECT 
    source_menu,
    COUNT(*) as view_count,
    AVG(time_spent) as avg_time_spent
FROM 
    my_ingested_data
GROUP BY 
    source_menu
ORDER BY 
    view_count DESC;
