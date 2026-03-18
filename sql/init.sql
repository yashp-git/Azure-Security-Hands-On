-- ============================================
-- Click Counter Database Schema
-- ============================================

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'ClickRecords')
BEGIN
    CREATE TABLE dbo.ClickRecords (
        Id          INT            IDENTITY(1,1) PRIMARY KEY,
        IpAddress   NVARCHAR(45)   NOT NULL,
        ClickedAt   DATETIME2(3)   NOT NULL DEFAULT GETUTCDATE()
    );

    CREATE NONCLUSTERED INDEX IX_ClickRecords_IpAddress
        ON dbo.ClickRecords (IpAddress)
        INCLUDE (ClickedAt);
END
GO
