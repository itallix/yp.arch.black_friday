# Миграция с MongoDB на Cassandra

## 1. Критически важные данные и целесообразность переноса

### Ключевые сущности

- **Orders (Заказы)**  
  Высокая скорость записи, идемпотентное создание, быстрый доступ к статусу и истории заказов.

- **Inventory (Остатки по SKU × зонам)**  
  Конкурентные обновления, необходима защита от oversell.

- **Carts (Корзины)**  
  Частые обновления, point-lookup по владельцу, TTL для очистки устаревших данных.

- **User sessions (Пользовательские сессии)**  
  Короткоживущие токены, высокая скорость записи/чтения, допускается eventual consistency.

### Почему Cassandra?

- Горизонтальное масштабирование без полного перераспределения данных (решение проблемы MongoDB range-sharding).
- Leaderless-репликация с гибкой настройкой уровней согласованности (`LOCAL_QUORUM`, `LOCAL_ONE`).
- Возможность проектирования таблиц под конкретные запросы (денормализация).
- Высокая производительность записи и отказоустойчивость.

### Что оставляем вне Cassandra?

- Product catalog с полнотекстовым поиском и фильтрацией: источник правды в Mongo, в Cassandra — только витрины для нагруженных листингов.

---

## 2. Концептуальная модель данных и выбор ключей

### Orders

```sql
CREATE TABLE order_by_id (
    order_id uuid PRIMARY KEY,
    user_id uuid,
    created_at timestamp,
    status text,
    geo_zone text,
    amount_total decimal,
    items frozen<list<frozen<tuple<uuid,text,text,decimal,int>>>>,
    idempotency_key text
);

CREATE TABLE orders_by_user_month (
    user_id uuid,
    yyyymm int,
    created_at timestamp,
    order_id uuid,
    status text,
    amount_total decimal,
    PRIMARY KEY ((user_id, yyyymm), created_at, order_id)
) WITH CLUSTERING ORDER BY (created_at DESC, order_id ASC);
```

- Разделение по уникальному `order_id` для равномерного распределения данных.
- История заказов пользователя с бакетизацией по месяцу (`yyyymm`) для ограничения размера партиций и эффективной сортировки.

### Inventory

```sql
CREATE TABLE inventory_by_sku_zone (
    sku uuid,
    zone text,
    bucket int,
    stock int,
    reserved int,
    updated_at timestamp,
    PRIMARY KEY ((sku, zone, bucket))
);

CREATE TABLE inventory_view_by_sku (
    sku uuid,
    zone text,
    stock int,
    reserved int,
    PRIMARY KEY ((sku), zone)
);
```

- Используется `bucket` для предотвращения "горячих" партиций.
- Отдельная таблица для быстрого просмотра по SKU без бакетирования.


### Carts

```sql
CREATE TABLE cart_by_owner (
    owner_id text,
    status text,
    cart_id uuid,
    updated_at timestamp,
    PRIMARY KEY ((owner_id))
);

CREATE TABLE cart_items_by_owner (
    owner_id text,
    product_id uuid,
    quantity int,
    updated_at timestamp,
    PRIMARY KEY ((owner_id), product_id)
);
```

- Партиционирование по `owner_id` (user_id или session_id) для равномерной нагрузки.
- Отдельная таблица для предметов корзины повышает гибкость доступа.


### Products

```sql
CREATE TABLE products_by_category_pricebucket (
    category text,
    price_bucket int,
    shard_id tinyint,
    price decimal,
    product_id uuid,
    name text,
    attrs_json text,
    PRIMARY KEY ((category, price_bucket, shard_id), price, product_id)
);
```

- Композитный ключ предотвращает горячие диапазоны за счёт сегментации по категории, ценовому диапазону и дополнительному "виртуальному" шардированию.

---


## 3. Стратегии обеспечения согласованности и целостности данных

 Стратегия | Применение | Обоснование                                    
-----------|------------|-------------
 **Hinted Handoff**     | Все таблицы               | Обеспечивает устойчивость при временной недоступности узлов (минимальные накладные расходы, быстрый догон)
 **Read Repair**        | Orders, Inventory         | Активное восстановление целостности при чтении 
 **Anti-Entropy Repair**| Регулярный фоновый процесс| Плановые сверки и исправления расхождений, с разной частотой для разных таблиц 


---

## План миграции

1. Включить двойную запись в MongoDB и Cassandra.
2. Сравнить результаты чтения и провести тёмные запуски (тестирование).
3. Переключить критичные операции чтения (заказы, корзины, запасы) на Cassandra.
4. Настроить мониторинг и регулярные процедуры восстановления данных (repair).
