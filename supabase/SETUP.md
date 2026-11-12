# Rich Click — настройка Supabase

Проект Supabase: `mpjrgurjmdueccaupkwu`

## 1. Создать таблицы и безопасные операции

1. Откройте Supabase Dashboard → SQL Editor → New query.
2. Скопируйте весь файл `supabase/schema.sql` из этого репозитория.
3. Нажмите Run.
4. Убедитесь, что запрос завершился без ошибок.

Схема создаёт профили, кошельки, инвентарь, каталог раритетов, рынок, две таблицы рейтингов и серверные RPC-функции. Балансы и предметы нельзя напрямую менять из браузера: операции покупки и передачи проходят через функции базы данных.

## 2. Настроить вход GitHub

1. В GitHub откройте Settings → Developer settings → OAuth Apps → New OAuth App.
2. Homepage URL: `https://asdasd-12.github.io/rich-click/`
3. Authorization callback URL: `https://mpjrgurjmdueccaupkwu.supabase.co/auth/v1/callback`
4. Создайте приложение и скопируйте Client ID.
5. Нажмите Generate a new client secret и сохраните его в менеджере паролей. Не публикуйте его в репозитории и не отправляйте в чат.
6. В Supabase откройте Authentication → Providers → GitHub, включите провайдер и вставьте Client ID и Client Secret.
7. В Supabase Authentication → URL Configuration задайте Site URL: `https://asdasd-12.github.io/rich-click/` и добавьте этот же адрес в Redirect URLs.

## 3. Ключи

Для браузера разрешён только Publishable key (или legacy anon key) вместе с Project URL. Никогда не помещайте в HTML, JavaScript или GitHub репозиторий `service_role`, `sb_secret_` или другие секретные ключи.

## 4. Проверка

После настройки провайдера вход нужно проверить на опубликованном сайте. Затем можно подключить клиентский интерфейс к таблицам и RPC. Не открывайте доступ на запись к кошелькам, инвентарю и объявлениям рынка через широкие RLS-политики.

## Ограничение раритетов

В базе предусмотрен пожизненный лимит: не более трёх приобретений каждого вида раритета на одного игрока. Покупки через магазин и через рынок учитываются вместе. Продажа предмета не восстанавливает лимит.
