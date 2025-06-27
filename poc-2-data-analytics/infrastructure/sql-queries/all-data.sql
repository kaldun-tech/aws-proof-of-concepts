-- Basic query to get all clickstream data
SELECT 
    element_clicked,
    time_spent,
    source_menu,
    created_at,
    datehour
FROM 
    my_ingested_data
ORDER BY 
    created_at DESC
LIMIT 100;
