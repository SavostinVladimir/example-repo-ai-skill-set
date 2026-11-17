## ADDED Requirements

### Requirement: Регистрация исходящих разрешений на ответ в личных сообщениях (`dm_thread_permissions`)
Система ДОЛЖНА (SHALL) фиксировать право собеседника на отправку ответных личных сообщений (Direct Messages) в специализированной таблице `dm_thread_permissions (account_id, target_account_id, conversation_id)` с уникальным составным B-Tree индексом `(account_id, target_account_id, conversation_id)` **исключительно** в тот момент, когда сам пользователь `account_id` публикует статус с видимостью `direct` (`visibility = 3`) и активным упоминанием (`silent = false`) пользователя `target_account_id`.

#### Scenario: Выдача разрешения при отправке пользователем личного сообщения
- **WHEN** пользователь `A` публикует статус с `visibility = direct` (новый или в ответ на существующий тред с `conversation_id`), содержащий не-тихое упоминание (`silent = false`) пользователя `B`
- **THEN** система атомарно создает запись в `dm_thread_permissions (account_id: A, target_account_id: B, conversation_id: status.conversation_id)` (`INSERT ... ON CONFLICT DO NOTHING`)

#### Scenario: Защита от инъекции третьих лиц в групповой переписке («Троянский конь»)
- **WHEN** пользователь `Bob` отправляет групповое личное сообщение, упоминая получателя `Alice` и стороннего аккаунта `Spammer`, при этом сама `Alice` еще ничего не отвечала `Spammer`
- **THEN** запись в `dm_thread_permissions` для пары `(account_id: Alice, target_account_id: Spammer)` НЕ создается, даже несмотря на добавление сообщения в `account_conversations` пользователя `Alice`

#### Scenario: Игнорирование ответов в публичных и непубличных (не-direct) ветках
- **WHEN** пользователь `Alice` отвечает пользователю `Bob` публичным (`public`), скрытым (`unlisted`) или доступным только подписчикам (`private`) постом
- **THEN** запись в `dm_thread_permissions` НЕ создается, и последующая попытка `Bob` написать `Alice` личное сообщение (`direct`) продолжает проверяться политиками `drop_private_mentions` / `filter_private_mentions`

---

### Requirement: Индексированная проверка ответа в треде вместо рекурсивного CTE
При оценке условий `private_mention_not_in_response?` в `NotifyService` (`DropCondition` и `FilterCondition`) система ДОЛЖНА (SHALL) проверять наличие разрешения в `dm_thread_permissions` через точечный `Index Only Scan` за $O(1)$ вместо рекурсивного обхода `WITH RECURSIVE ancestors` на 100 уровней вглубь, сохраняя изоляцию от остальных политик фильтрации (`not_following`, `new_accounts`, `bots`).

#### Scenario: Мгновенный пропуск ответа в разрешенном DM-треде
- **WHEN** пользователь `B` отправляет ответное личное сообщение (`in_reply_to_id IS NOT NULL`, `visibility = direct`) пользователю `A` в рамках `conversation_id`, и в `dm_thread_permissions` существует запись `(account_id: A, target_account_id: B, conversation_id: status.conversation_id)` (при подтвержденной принадлежности родительского поста к данному `conversation_id`)
- **THEN** `response_to_recipient?` возвращает `true` за один индексный запрос к `dm_thread_permissions` без запуска рекурсивного CTE по таблицам `statuses` и `mentions`

#### Scenario: Блокировка новых несвязанных DM-тредов от того же собеседника
- **WHEN** пользователь `B`, ранее получивший разрешение в треде `conv_1`, отправляет пользователю `A` новое личное сообщение вне этого треда (`in_reply_to_id IS NULL` или в другом `conversation_id`)
- **THEN** запрос к `dm_thread_permissions` для нового `conversation_id` возвращает `false`, и сообщение фильтруется или отбрасывается согласно политике `for_private_mentions`, а все прочие фильтры (`for_not_following`, `for_new_accounts`) для публичных упоминаний и реакций пользователя `B` остаются активными

---

### Requirement: Отзыв разрешения при блокировке аккаунта или удалении исходящего DM
Система ДОЛЖНА (SHALL) аннулировать записи в `dm_thread_permissions` при блокировке собеседника, блокировке его домена или удалении/редактировании всех исходящих личных сообщений пользователя в данном треде.

#### Scenario: Очистка разрешений при блокировке пользователя или домена
- **WHEN** пользователь `A` блокирует пользователя `B` (`AfterBlockService`) или его домен (`AfterBlockDomainFromAccountService`)
- **THEN** все записи `dm_thread_permissions` для `(account_id: A, target_account_id: B)` удаляются
