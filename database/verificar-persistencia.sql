/*
    Consultas da apresentacao.
    Rode o bloco correspondente no Query Editor logo depois de cada operacao.
*/

-- Estrutura das FKs
SELECT
    fk.name AS foreign_key,
    OBJECT_NAME(fk.parent_object_id) AS tabela_detail,
    COL_NAME(fc.parent_object_id, fc.parent_column_id) AS coluna_detail,
    OBJECT_NAME(fk.referenced_object_id) AS tabela_master,
    COL_NAME(fc.referenced_object_id, fc.referenced_column_id) AS coluna_master
FROM sys.foreign_keys fk
INNER JOIN sys.foreign_key_columns fc ON fk.object_id = fc.constraint_object_id
ORDER BY tabela_detail;

-- 1) Depois do POST /api/Passageiro
SELECT id_passageiro, nome, cpf, idade, status_medico FROM passageiro;

-- 2) Depois do GET /api/Passageiro/1
SELECT id_passageiro, nome, cpf, idade, status_medico FROM passageiro WHERE id_passageiro = 1;

-- 3) Depois do PUT /api/Passageiro/1
SELECT id_passageiro, nome, cpf, idade, status_medico FROM passageiro WHERE id_passageiro = 1;

-- 4) Depois do POST /api/Traje (detail ligado ao master)
SELECT
    t.id_traje,
    t.codigo_rfid,
    t.dt_alocacao,
    t.id_passageiro,
    p.nome AS passageiro,
    p.cpf
FROM traje t
INNER JOIN passageiro p ON p.id_passageiro = t.id_passageiro;

-- 5) Depois do GET /api/Traje
SELECT id_traje, codigo_rfid, id_passageiro FROM traje;

-- 6) Depois do PUT /api/Traje/1
SELECT id_traje, codigo_rfid, id_passageiro, dt_alocacao FROM traje WHERE id_traje = 1;

-- 7) Depois do DELETE /api/Traje/1
SELECT id_traje, codigo_rfid, id_passageiro FROM traje;

-- 8) Depois do DELETE /api/Passageiro/1
SELECT id_passageiro, nome, cpf FROM passageiro;
SELECT id_traje, codigo_rfid, id_passageiro FROM traje;

SELECT MigrationId, ProductVersion FROM __EFMigrationsHistory;
