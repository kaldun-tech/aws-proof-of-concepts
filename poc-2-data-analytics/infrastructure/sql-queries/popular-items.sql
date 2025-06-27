-- Query for popular menu items
SELECT 
    element_clicked,
    COUNT(*) as view_count,
    AVG(time_spent) as avg_time_spent,
    MIN(time_spent) as min_time_spent,
    MAX(time_spent) as max_time_spent
FROM 
    my_ingested_data
GROUP BY 
    element_clicked
ORDER BY 
    view_count DESC;
