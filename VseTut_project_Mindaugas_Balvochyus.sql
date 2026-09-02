--1. Общая информация
WITH inter_1 AS 
(
 SELECT DISTINCT u.user_id, u.region, min(o.order_purchase_ts) AS first_order_ts, max(o.order_purchase_ts) AS last_order_ts,
 (max(o.order_purchase_ts) - min(o.order_purchase_ts)) as lifetime
 FROM ds_ecom.users AS u JOIN ds_ecom.orders AS o ON u.buyer_id = o.buyer_id
 WHERE order_status in ('Доставлено', 'Отменено') 
 GROUP BY u.region, u.user_id
 ORDER BY u.region
),

inter_review_cast AS 
(
 SELECT order_id, 
 CASE
 	WHEN review_score > 5 THEN review_score/10
 	ELSE review_score
 END AS review_score_cast
 FROM ds_ecom.order_reviews
 GROUP BY order_id, review_score_cast  
),

--2. Информация о заказах клиента
inter_2 AS
(
 SELECT DISTINCT u.user_id, u.region,  
 count(o.order_id) AS total_orders, 
 avg(ore.review_score_cast) AS avg_order_rating,
 count(o.order_id) filter(WHERE ore.review_score_cast IS NOT null) AS num_orders_with_rating,
 count(o.order_id) filter(WHERE o.order_status = 'Отменено') AS num_canceled_orders,
 (count(o.order_id) filter(WHERE o.order_status = 'Отменено')) :: real/count(o.order_id) AS canceled_orders_ratio
 FROM ds_ecom.users AS u JOIN ds_ecom.orders AS o ON u.buyer_id = o.buyer_id
 JOIN inter_review_cast AS ore ON o.order_id = ore.ORDER_id
 WHERE order_status in ('Доставлено', 'Отменено') 
 GROUP BY region, user_id
 ORDER BY total_orders desc 
),

inter_pay_order AS 
(
 SELECT oi.order_id, payment_type, price, delivery_cost, payment_installments
 FROM ds_ecom.order_items AS oi JOIN ds_ecom.order_payments AS op ON op.order_id = oi.order_id
 GROUP BY oi.order_id, payment_type, price, delivery_cost, payment_installments
),

--3. Информация о платежах 
inter_3 AS 
(
 SELECT DISTINCT u.user_id, u.region,  
 sum(price + delivery_cost) FILTER(WHERE o.order_status = 'Доставлено') AS total_order_costs,
 avg(price + delivery_cost) FILTER(WHERE o.order_status != 'Отменено') AS avg_order_cost,
 count(*) FILTER(WHERE payment_installments > 1) AS num_installment_orders,
 count(*) FILTER(WHERE payment_type = 'промокод') AS num_orders_with_promo
 FROM ds_ecom.orders AS o JOIN inter_pay_order AS op ON o.order_id = op.order_id
 JOIN ds_ecom.users AS u ON u.buyer_id = o.buyer_id
 --JOIN ds_ecom.order_items AS oi ON oi.order_id = o.order_id
 WHERE order_status in ('Доставлено', 'Отменено') 
 GROUP BY u.user_id, u.region  
), 

--4. Вспомогательные бинарные признаки
inter_4 AS 
(
 SELECT u.user_id, u.region, 
 max(CASE 
	WHEN payment_type = 'денежный перевод' AND payment_sequential = 1 THEN '1'
	ELSE '0'
 END) AS used_money_transfer,

 max(CASE 
	WHEN payment_installments != 1 THEN '1' 
	ELSE '0'
 END) AS used_installments,

 max(CASE 
	WHEN order_status = 'Отменено' THEN '1' 
 	ELSE '0'
 END) AS used_cancel

 FROM ds_ecom.orders AS o JOIN ds_ecom.order_payments AS op ON o.order_id = op.order_id
 JOIN ds_ecom.users AS u ON u.buyer_id = o.buyer_id
 JOIN ds_ecom.order_items AS oi ON oi.order_id = o.order_id
 WHERE order_status in ('Доставлено', 'Отменено')
 GROUP BY u.user_id, u.region-- used_money_transfer, used_installments, used_cancel
),

--фильтрация по трем самым активным регионам
top_region AS 
(
SELECT i1.region, sum(i2.total_orders) AS region_total_orders  
FROM inter_1 AS i1 LEFT JOIN inter_2 AS i2 ON i1.user_id = i2.user_id
GROUP BY i1.region
ORDER BY region_total_orders DESC
LIMIT 3 
)

--витрина данных 
SELECT DISTINCT i1.user_id, i1.region, first_order_ts, last_order_ts, lifetime, total_orders, avg_order_rating, num_orders_with_rating, num_canceled_orders,
canceled_orders_ratio, total_order_costs, avg_order_cost, num_installment_orders, num_orders_with_promo, used_money_transfer, used_installments, used_cancel
FROM 
inter_1 AS i1 LEFT JOIN inter_2 AS i2 ON i1.user_id = i2.user_id AND i1.region = i2.region
LEFT JOIN inter_3 AS i3 ON i1.user_id = i3.user_id AND i1.region = i2.region
LEFT JOIN inter_4 AS i4 ON i1.user_id = i4.user_id AND i1.region = i2.region
WHERE i1.region IN (SELECT region FROM top_region)
ORDER BY total_orders;


--ad hoc
--сегментация пользователей 
SELECT count(*) AS con_user_in_group,  
CASE 
	WHEN total_orders = 1 THEN '1 заказ'
	WHEN total_orders BETWEEN 2 AND 5 THEN '2—5 заказов'
	WHEN total_orders BETWEEN 6 AND 10 THEN '6–10 заказов'
	WHEN total_orders >= 11 THEN '11 и более заказов'
	ELSE ''
END AS ranks 
FROM ds_ecom.product_user_features
GROUP BY ranks ORDER BY con_user_in_group; 
/*
комментарий
В группе "11 и более заказов" только 1 пользователь.
Наибольшее число пользователей совершает не более одного заказа.
группа пользователей с заказми от 11 и более самая малочисленная. 
*/

--ранжирование пользователей
SELECT *,
dense_rank() OVER(ORDER BY total_order_costs desc) AS ranks 
FROM ds_ecom.product_user_features
WHERE total_orders >= 3 LIMIT 15;
/*
комментарий
покупатель из Петербурга с id 1da09dd64e235e7c2f29a4faff33535c имеет самый большой чек и самый высокий средний показатель по стоимости.
покупатель из Москвы с id 8d50f5eadf50201ccdcedfb9e2ac8455 имеет самый большой разрыв датах первого и последнего заказа. Можно наградить его промокодом за преданность. 
По метрике lifetime наблюдается сильный разброс. 
*/

--статистика по регионам 
SELECT region,
count(user_id) AS total_users,
sum(total_orders) AS total_orders,
(sum(total_orders) FILTER(WHERE num_installment_orders != 0)) :: real/sum(total_orders) AS part_installment,
(sum(total_orders) FILTER(WHERE num_orders_with_promo != 0)) :: REAL/sum(total_orders) AS part_promo,
count(user_id) FILTER(WHERE num_canceled_orders != 0) :: REAL/count(user_id) AS part_cancel 
FROM ds_ecom.product_user_features
GROUP BY region;
/*
комментарий 
Москва является лидером по покупателям, в 3 раза опережая ближайшие регионы. 
Москва является лидером по количеству заказо, в 3.3 раза опережая ближайшие регионы.
Процент рассрочек ниже в Москве на 7%, другие регионы их топ-3 имеют примерно равные показатели в 55%
Доля оплаты промокодом незначительно выше в Петербурге.
На Москву приходится наибольшее количество отказов из топ-3 регионов.
*/

--активность пользователей по месяцу первого заказа в 2023 году
SELECT
EXTRACT (MONTH FROM first_order_ts) AS month_order,
EXTRACT (YEAR FROM first_order_ts) AS year_order,
count(user_id) AS con_user,
sum(total_orders) AS sum_orders,
avg(total_order_costs) AS avg_cost,

avg(avg_order_rating) AS avg_rating,
(count(used_installments) FILTER(WHERE used_installments = 1)) :: real/count(user_id) AS part_user_installments,
avg(lifetime) AS avg_activ

FROM ds_ecom.product_user_features
WHERE EXTRACT (YEAR FROM first_order_ts) = '2023'
GROUP BY month_order, year_order; 
/*
комментрарий 
первый месяц существенно меньше по количеству покупателей и количеству заказав, при среднем чекеm сопоставивым с другими месяцами. 
самый активный месяц по заказам и пользователям 11 (ноябрь). 
средний рейтинг не опускается ниже 4. 
средний чек находится в диапозоне 2700 - 3500. Самый большой средний чек в сентябре. 
в среднем 50% покупателей пользуются рассрочкой. 
активность в среднем состовляет от 2 до 13 дней. 
*/