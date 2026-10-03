/*
    StellarGear - Azure SQL Database
    2o Checkpoint - Aplicacoes e Banco em Nuvem
    Turma 2TDSPF

    Modelo master-detail da apresentacao:
      passageiro (master) 1 --- N traje (detail)
      FK: FK_traje_passageiro_id_passageiro
          (traje.id_passageiro -> passageiro.id_passageiro)

    Demais relacionamentos:
      historico_medico.id_passageiro -> passageiro.id_passageiro
      leitura_sensor.id_traje        -> traje.id_traje
      alerta_emergencia.id_leitura   -> leitura_sensor.id_leitura
      alerta_emergencia.id_medico    -> medico.id_medico

    A API aplica este mesmo modelo na inicializacao quando
    Database__AutoMigrate=true. O INSERT em __EFMigrationsHistory
    evita que a migracao tente criar as tabelas de novo.

    Execute no Query Editor do banco StellarGearDb.
    Se as tabelas ja existirem, o script nao recria o que ja existe.
*/

IF OBJECT_ID(N'[__EFMigrationsHistory]', N'U') IS NULL
BEGIN
    CREATE TABLE [__EFMigrationsHistory] (
        [MigrationId] nvarchar(150) NOT NULL,
        [ProductVersion] nvarchar(32) NOT NULL,
        CONSTRAINT [PK___EFMigrationsHistory] PRIMARY KEY ([MigrationId])
    );
END
GO

IF OBJECT_ID(N'[medico]', N'U') IS NULL
BEGIN
    CREATE TABLE [medico] (
        [id_medico] int NOT NULL IDENTITY(1, 1),
        [nome] nvarchar(100) NOT NULL,
        [crm] nvarchar(20) NOT NULL,
        [especialidade] nvarchar(50) NULL,
        [DataCriacao] datetime2 NOT NULL,
        CONSTRAINT [PK_medico] PRIMARY KEY ([id_medico])
    );
END
GO

IF OBJECT_ID(N'[passageiro]', N'U') IS NULL
BEGIN
    CREATE TABLE [passageiro] (
        [id_passageiro] int NOT NULL IDENTITY(1, 1),
        [nome] nvarchar(100) NOT NULL,
        [cpf] nvarchar(14) NOT NULL,
        [idade] int NULL,
        [status_medico] nvarchar(50) NULL,
        [DataCriacao] datetime2 NOT NULL,
        CONSTRAINT [PK_passageiro] PRIMARY KEY ([id_passageiro])
    );
END
GO

IF OBJECT_ID(N'[historico_medico]', N'U') IS NULL
BEGIN
    CREATE TABLE [historico_medico] (
        [id_historico] int NOT NULL IDENTITY(1, 1),
        [id_passageiro] int NOT NULL,
        [diagnostico] nvarchar(500) NULL,
        [dt_registro] datetime2 NULL,
        [DataCriacao] datetime2 NOT NULL,
        CONSTRAINT [PK_historico_medico] PRIMARY KEY ([id_historico]),
        CONSTRAINT [FK_historico_medico_passageiro_id_passageiro]
            FOREIGN KEY ([id_passageiro]) REFERENCES [passageiro] ([id_passageiro]) ON DELETE CASCADE
    );

    CREATE INDEX [IX_historico_medico_id_passageiro] ON [historico_medico] ([id_passageiro]);
END
GO

IF OBJECT_ID(N'[traje]', N'U') IS NULL
BEGIN
    CREATE TABLE [traje] (
        [id_traje] int NOT NULL IDENTITY(1, 1),
        [id_passageiro] int NOT NULL,
        [codigo_rfid] nvarchar(50) NULL,
        [dt_alocacao] datetime2 NULL,
        [DataCriacao] datetime2 NOT NULL,
        CONSTRAINT [PK_traje] PRIMARY KEY ([id_traje]),
        CONSTRAINT [FK_traje_passageiro_id_passageiro]
            FOREIGN KEY ([id_passageiro]) REFERENCES [passageiro] ([id_passageiro]) ON DELETE CASCADE
    );

    CREATE INDEX [IX_traje_id_passageiro] ON [traje] ([id_passageiro]);
END
GO

IF OBJECT_ID(N'[leitura_sensor]', N'U') IS NULL
BEGIN
    CREATE TABLE [leitura_sensor] (
        [id_leitura] int NOT NULL IDENTITY(1, 1),
        [id_traje] int NOT NULL,
        [temperatura] decimal(5, 2) NULL,
        [humidade] decimal(5, 2) NULL,
        [batimentos] decimal(5, 2) NULL,
        [dt_leitura] datetime2 NULL,
        [DataCriacao] datetime2 NOT NULL,
        CONSTRAINT [PK_leitura_sensor] PRIMARY KEY ([id_leitura]),
        CONSTRAINT [FK_leitura_sensor_traje_id_traje]
            FOREIGN KEY ([id_traje]) REFERENCES [traje] ([id_traje]) ON DELETE CASCADE
    );

    CREATE INDEX [IX_leitura_sensor_id_traje] ON [leitura_sensor] ([id_traje]);
END
GO

IF OBJECT_ID(N'[alerta_emergencia]', N'U') IS NULL
BEGIN
    CREATE TABLE [alerta_emergencia] (
        [id_alerta] int NOT NULL IDENTITY(1, 1),
        [id_leitura] int NOT NULL,
        [id_medico] int NOT NULL,
        [descricao] nvarchar(200) NULL,
        [nivel_gravidade] nvarchar(20) NULL,
        [resolvido] nvarchar(1) NOT NULL,
        [dt_alerta] datetime2 NULL,
        [DataCriacao] datetime2 NOT NULL,
        CONSTRAINT [PK_alerta_emergencia] PRIMARY KEY ([id_alerta]),
        CONSTRAINT [FK_alerta_emergencia_leitura_sensor_id_leitura]
            FOREIGN KEY ([id_leitura]) REFERENCES [leitura_sensor] ([id_leitura]) ON DELETE CASCADE,
        CONSTRAINT [FK_alerta_emergencia_medico_id_medico]
            FOREIGN KEY ([id_medico]) REFERENCES [medico] ([id_medico]) ON DELETE NO ACTION
    );

    CREATE INDEX [IX_alerta_emergencia_id_leitura] ON [alerta_emergencia] ([id_leitura]);
    CREATE INDEX [IX_alerta_emergencia_id_medico] ON [alerta_emergencia] ([id_medico]);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002183453_InitialSqlServer'
)
BEGIN
    INSERT INTO [__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES (N'20261002183453_InitialSqlServer', N'10.0.8');
END
GO
