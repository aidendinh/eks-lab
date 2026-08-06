# Schema

### customers
- id: integer (pk)
- name: varchar (required)
- tier: varchar (required)

### orders
- id: int auto_increment (pk)
- customer_id: integer (required, fk)
- status: varchar (required)
- total_cents: integer (required)

### order_items
- id: int auto_increment (pk)
- order_id: integer (required, fk)
- sku: varchar (required)
- quantity: integer (required)

### numbers
- n: integer (pk)
