CREATE procedure dbo.verify
@stmt varchar(256)
as
BEGIN
declare @doit varchar(256)
create table #mytable
(
counts int
)
set @doit = 'insert into #mytable '+@stmt
EXEC (@doit)
declare @doit_count int = (select counts from #mytable)
IF @doit_count=0 or @doit_count is null
BEGIN
raiserror (N'Error', -- Message text.
25, -- Severity,
1 -- State
) with log;
END
drop table #mytable
END
