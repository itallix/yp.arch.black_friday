# Проектирование схем коллекций для шардирования данных

## Коллекции

### orders

заказы, история пользователей, статусы

```json
{
  "_id": "ObjectId/UUID",        // order_id
  "user_id": "string/UUID",
  "created_at": "date",
  "status": "string",            // e.g. "new", "paid", "shipped", "delivered", "canceled"
  "geo_zone": "string",          // геозона заказа (место доставки/магазина)
  "items": [
    { "product_id": "ObjectId/UUID", "name": "string", "category": "string",
      "price": "number", "quantity": "int" }
  ],
  "amount_total": "number"
}
```

**Основные индексы:**

- `{ user_id: 1, created_at: -1 }` — история заказов и пагинация.
- `{ _id: 1 }` — по умолчанию (статус заказа по id).
- `{ geo_zone: 1, created_at: 1 }` — аналитика по регионам.

### products

карточка товара + остатки по геозонам

```json
{
  "_id": "ObjectId/UUID",
  "name": "string",
  "category": "string",          // e.g. "Электроника", "Бытовая техника"
  "price": "number",             // в базовой валюте
  "price_bucket": "int",         // floor(price / 100) — для шардинга и поиска по диапазонам
  "attrs": {                     // произвольные характеристики
    "color": "string",
    "size": "string",
    "...": "..."
  },
  "inventory": [                 // массив по геозонам {zone, qty} удобен для целевых обновлений (inventory.$ + arrayFilters) и позволяет индексировать inventory.zone
    { "zone": "string", "qty": "int", "reserved": "int" }
  ],
  "updated_at": "date"
}
```

**Основные индексы:**

- `{ category: 1, price_bucket: 1, price: 1 }` — поиск по категории + диапазон цены (или bucket → потом точный фильтр по price).
- `{ name: "text" }` — упрощённый поиск по названию.
- `{ "inventory.zone": 1 }` — точечные выборки остатков по зоне (для страниц товара).
- `{ updated_at: -1 }` — фоновые процедуры/витрины.

### carts

текущие корзины, активные для гостей и пользователей

```json
{
  "_id": "ObjectId/UUID",
  "user_id": "string/UUID|null",
  "session_id": "string|null",
  "owner_type": "string",        // "user" | "guest"
  "owner_id": "string/UUID",     // user_id || session_id (обязателен) - для шардирования
  "status": "string",            // "active" | "ordered" | "abandoned"
  "items": [ { "product_id": "ObjectId/UUID", "quantity": "int" } ],
  "created_at": "date",
  "updated_at": "date",
  "expires_at": "date"           // TTL для очистки неактивных
}
```

**Основные индексы:**

- `{ owner_id: 1, status: 1 }` — получение активной корзины владельца.
- `{ session_id: 1, status: 1 }` и `{ user_id: 1, status: 1 }` — для обратной совместимости.
- `{ expires_at: 1 }` TTL (expireAfterSeconds: 0).
- `{ updated_at: -1 }` — задачи очистки.

## Выбор шард-ключей и стратегия

### orders: `{ user_id: "hashed" }`

- Основная выборка — «история заказов пользователя» → таргетируемся по user_id на один шард.
- Вставки распределяются равномерно (нет горячих чанков), т.к. hashed.
- Запрос «статус заказа» можно сделать таргетированным, если в API (или в токене) есть user_id → фильтр { _id, user_id }. Это обычная практика в B2C (авторизованный пользователь).

### products: `{ category: 1, price_bucket: 1 } (ranged)`

- Главные запросы — «категория + диапазон цен». Ранжевый составной ключ позволяет направленно читать только нужный диапазон чанков внутри категории (без полного scatter).
- price_bucket = floor(price/100) даёт устойчивую сегментацию по цене, позволяет пред-сплитить диапазоны и распылить «тяжёлые» категории по шардам.
- Обновления остатков выполняются по _id + элементу массива inventory.zone — они попадают на ровно один документ, следовательно на один шард (по его shard key значениям category, price_bucket). Приложение знает category/price_bucket из карточки товара, поэтому может включить их в фильтр апдейта, чтобы роутер таргетировал верно.

### carts: `{ owner_id: "hashed" }`

- Почти все операции (создать/получить активную корзину/обновить/слить) — по «владельцу» (пользователь или гость). Хеш-ключ даёт равномерную нагрузку и таргетинг на один шард.
- Не возникает «горячей точки», потому что в пике корзин много, а владельцы распределены.

## Команды

1. Включаем шардинг и создаем коллекции с валидацией

```javascript

use mm;
sh.enableSharding("mm");

// PRODUCTS
db.createCollection("products", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["name","category","price","price_bucket","inventory"],
      properties: {
        name: { bsonType: "string" },
        category: { bsonType: "string" },
        price: { bsonType: ["double","decimal","int","long"] },
        price_bucket: { bsonType: "int" },
        inventory: {
          bsonType: "array",
          items: {
            bsonType: "object",
            required: ["zone","qty"],
            properties: {
              zone: { bsonType: "string" },
              qty: { bsonType: "int" },
              reserved: { bsonType: "int" }
            }
          }
        },
        updated_at: { bsonType: "date" }
      }
    }
  }
});

// ORDERS
db.createCollection("orders", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["user_id","created_at","status","items","amount_total","geo_zone"],
      properties: {
        user_id: { bsonType: ["string","objectId","binData"] },
        created_at: { bsonType: "date" },
        status: { bsonType: "string" },
        geo_zone: { bsonType: "string" },
        amount_total: { bsonType: ["double","decimal","int","long"] },
        items: {
          bsonType: "array",
          items: {
            bsonType: "object",
            required: ["product_id","price","quantity"],
            properties: {
              product_id: { bsonType: ["objectId","binData","string"] },
              name: { bsonType: "string" },
              category: { bsonType: "string" },
              price: { bsonType: ["double","decimal","int","long"] },
              quantity: { bsonType: "int" }
            }
          }
        }
      }
    }
  }
});

// CARTS
db.createCollection("carts", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["owner_type","owner_id","status","items","created_at","updated_at","expires_at"],
      properties: {
        user_id: { bsonType: ["string","objectId","binData","null"] },
        session_id: { bsonType: ["string","null"] },
        owner_type: { enum: ["user","guest"] },
        owner_id: { bsonType: ["string","objectId","binData"] },
        status: { enum: ["active","ordered","abandoned"] },
        items: {
          bsonType: "array",
          items: {
            bsonType: "object",
            required: ["product_id","quantity"],
            properties: {
              product_id: { bsonType: ["objectId","binData","string"] },
              quantity: { bsonType: "int", minimum: 1 }
            }
          }
        },
        created_at: { bsonType: "date" },
        updated_at: { bsonType: "date" },
        expires_at: { bsonType: "date" }
      }
    }
  }
});
```

2. Индексы

```javascript
// products
db.products.createIndex({ category: 1, price_bucket: 1, price: 1 });
db.products.createIndex({ name: "text" });
db.products.createIndex({ "inventory.zone": 1 });
db.products.createIndex({ updated_at: -1 });

// orders
db.orders.createIndex({ user_id: 1, created_at: -1 });
db.orders.createIndex({ geo_zone: 1, created_at: 1 });

// carts
db.carts.createIndex({ owner_id: 1, status: 1 });
db.carts.createIndex({ session_id: 1, status: 1 });
db.carts.createIndex({ user_id: 1, status: 1 });
db.carts.createIndex({ expires_at: 1 }, { expireAfterSeconds: 0 });
```

3. Шардирование (ключи и шард-коллекции)

```javascript
// orders: таргетинг по пользователю, равномерность вставок
sh.shardCollection("mm.orders", { user_id: "hashed" });

// products: направленный поиск по категории + диапазону цены (bucket)
sh.shardCollection("mm.products", { category: 1, price_bucket: 1 });

// carts: равномерность и таргетинг по владельцу
sh.shardCollection("mm.carts", { owner_id: "hashed" });
```
