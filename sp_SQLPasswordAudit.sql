IF OBJECT_ID(N'[dbo].[sp_SQLPasswordAudit]') IS NULL
  EXEC (N'CREATE PROCEDURE [dbo].[sp_SQLPasswordAudit] AS RETURN 0;');
GO


ALTER PROCEDURE [dbo].[sp_SQLPasswordAudit]
(
	@Help				BIT				= 0,
	@ExcludeDisabled	BIT				= 1,
	@IgnorePolicy		BIT				= 0,
	@ResultsToTable		BIT				= 0,
	@SourceLists		NVARCHAR(500)	= N'ALL',
	@UseInstanceInfo	BIT				= 0,
	@CustomTerm		NVARCHAR(32)		= N''
)
AS
SET NOCOUNT ON;
DECLARE		@Delim		NVARCHAR(1) 			= N',';
DECLARE		@IsDisabled	BIT				= 0;

IF (@Help = 1)
BEGIN
PRINT '
	SQLPasswordAudit from https://github.com/TheVladdestVlad/SQLPasswordAudit
	This stored procedure checks the passwords of your existing SQL Logins against
	popular password lists.
	Experimental: The stored procedure can also generate custom instance-specific 
	passwords using information like:
		- database names and creation dates
		- login names and creation dates
		- instance name and creation date
		- common terms found in passwords
		- symbols
		- custom term (company name, project name, etc.) provided by the user
		These are combined using common password paterns.
		To learn more, visit https://github.com/TheVladdestVlad/SQLPasswordAudit, where
	you can download updated versions of the script and of the password lists, as well as 
	find detailed usage information and contribute your own code and suggestions.

	Limitations:
	This has only been developed for and tested on SQL Server 2012 through 2019.
	In the cases of logins migrated from older instances, the creation date would 
	no longer help, since it no longer matches the original creation date of the 
	login(s) on the source instance.

	Heads-up:
	Running PWDCOMPARE, the function that this script calls to perform  
	the comparison between the clear text password candidates and the password_hash column 
	of sys.sql_login, against large password lsits will cause PREEMPTIVE_OS_CRYPTOPS waits 
	to increase.
	https://www.sqlskills.com/help/waits/preemptive_os_cryptops/
	If you execute the stored procedure with option to generate passwords based on instance 
	information and custom term on an instance that has many (20+) databases and logins, 
	the quasi-temporary table [dbo].[TempCustomPasswords] created during execution will 
	end up storing a lot of data. Be prepared and pre-grow the data file by a few GB.
	It is higly recommended to have this stored procedure and the [dbo].[Passwords] table
	in a non-system databases that is dedicated to DBA-related tasks and can be set to use 
	the SIMPLE recovery model.

	 Dependencies:
	 If you wish to run the stored procedure against password lists,the [dbo].[Passwords] 
	 table needs to be created in the same database as the stored procedure, and it also 
	 has to be populated with the password list(s) you intend to use.
	 The table and various password list scripts designed for this store procedure
	 can be found here -> https://github.com/TheVladdestVlad/SQLPasswordAudit/tree/master/PasswordLists

	 Parameter explanations:
		@ExcludeDisabled = Used to specify whether logins marked as disabled should be skipped or not. 
							Default is 1 (yes)
		@IgnorePolicy    = Specifies whether or not passwords shorter than 8 characters should be checked 
							against hashes of logins where is_policy_checked is set to 1.
							Default is 0 (check passwords < 8 characters only against 
							logins having is_policy_checked= 0).
		@ResultsToTable	 =  Specifies whether or not the results of the check should be saved in a permanent table 
							(the table is created by the stored procedure). Default is 0 (No)
		@SourceLists	 = Name(s) of the source lists, comma separated, that should be checked against 
						(e.g. rockyou, nansh0u, etc.), based on the ones existing in the [dbo].[Passwords] table.
						 If you plan on only using instance-specific auto-generated passwords, provide a name that 
						 doesn''t exist (e.g nolist). Default is ALL.
		@UseInstanceInfo = Specifies wheter or not the stored procedure should auto generate
							instance-specific passwords and includem them in the check. Default is 0 (No)
		@CustomTerm		 =	Used to pass a single custom term when the stored procedure should generat
							instance-specific passwords.
							This can be something like comapny name or the name of an internal project.
							Default is '''' (an epmty string).

	MIT License

	Copyright (c) 2024 Vlad Drumea
	
	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:
	
	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.
	
	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.
	'
	RETURN
END

  IF OBJECT_ID('tempdb..#SelectedLists') IS NOT NULL
	BEGIN
			DROP TABLE #SelectedLists;
	END;
 CREATE TABLE #SelectedLists
	(ListName nvarchar(60),
	StartPosition int,
	Selected bit);

/* Handle @ExcludeDisabled */
IF (@ExcludeDisabled = 0)
BEGIN
SET @IsDisabled = 1;
END;

/*
	Creating a table to store custom passwords - will be dropped in the cleanup step
*/
IF EXISTS(SELECT * FROM sys.objects 
	WHERE [object_id] = OBJECT_ID(N'[dbo].[TempCustomPasswords]') AND [type] in (N'U'))
	BEGIN
		DROP TABLE [dbo].[TempCustomPasswords];
	END;
CREATE TABLE [dbo].[TempCustomPasswords]
(
[ID] INT IDENTITY(1,1) PRIMARY KEY CLUSTERED NOT NULL,
[Pass] NVARCHAR(128),
[SourceList] NVARCHAR(128)
);

/* Prep for instance-specific and/or custom term-based password generation */

IF (@UseInstanceInfo=1 OR @CustomTerm <> N'')
BEGIN
	IF NOT EXISTS (SELECT * FROM sys.objects
			WHERE [object_id] = OBJECT_ID(N'[dbo].[Passwords]') AND [type] in (N'U'))
		BEGIN
		CREATE TABLE [dbo].[Passwords]
			(
			[ID] [int] IDENTITY(1,1) PRIMARY KEY CLUSTERED NOT NULL,
			[Pass] [nvarchar](128) NULL,
			[SourceList] [nvarchar](128) NULL
			);
		END;
DECLARE @InstanceCreated VARCHAR(10);
DECLARE @CurrentYear VARCHAR(4);
DECLARE @InstanceName NVARCHAR(16);

/* Set @InstanceName */
SELECT @InstanceName =	CAST(
							ISNULL(
								SERVERPROPERTY('InstanceName'),
								SERVERPROPERTY('ServerName')
							) AS NVARCHAR(16)
							);

/* Set @CurrentYear */
SELECT @CurrentYear = CAST(
						CONVERT(VARCHAR,GETDATE(),23) AS VARCHAR(4)
							);
/* Set @InstanceCreated*/
SELECT @InstanceCreated = CONVERT(VARCHAR,[create_date],23)
FROM sys.server_principals
WHERE sid = 0x010100000000000512000000;

/*
	Create the tamp table that will store instance-related data 
	and common terms to be used for password combinations
*/
  IF OBJECT_ID('tempdb..#CustomPassCombo') IS NOT NULL
	BEGIN
			DROP TABLE #CustomPassCombo;
	END;
CREATE TABLE #CustomPassCombo
( 
	[InstanceInfo]		NVARCHAR(52),
	[CommonTerms]		NVARCHAR(14),
	[DatabaseCreated]	VARCHAR(10),
	[LoginCreated]		VARCHAR(10)
  )
/* 
	Declare @CommonTerms table variable to store terms commonly found in passwords 
*/
DECLARE @CommonTerms TABLE 
	(
		[CommTerms]		NVARCHAR(20)
	);

/* 
	Populate the @CommonTerms table variable 
*/
INSERT INTO @CommonTerms
([CommTerms])
VALUES
(N'Owner'),(N'Admin'),(N'Adm'),(N'Administrator'),(N'Root'),(N'SA'),(N'Manage'),
(N'ReadOnly'),(N'Read_Only'),(N'Read-Only'),(N'Read Only'),(N'R/O'),(N'R.O.'),
(N'R.O'),(N'R.O.'),(N'R-O'),(N'R_O'),(N'RO'),(N'R O'),(N'ReadWrite'),(N'Read_Write'),
(N'Read-Write'),(N'Read Write'),(N'R/W'),(N'R.W.'),(N'R.W'),(N'R-W'),(N'R_W'),
(N'R W'),(N'RW'),(N'Write'),(N'SysAdmin'),(N'Sys_Admin'),(N'Sys-Admin'),(N'Sys Admin'),
(N'Sys'),(N'System'),(N'IT'),(N'I.T.'),(N'DDB'),(N'Dev'),(N'Develop'),(N'Developer'),
(N'Development'),(N'TDB'),(N'Test'),(N'TestDB'),(N'Tester'),(N'QA'),(N'QADB'),
(N'Assurance'),(N'ADB'),(N'SB'),(N'SBDB'),(N'SandBox'),(N'Sand_Box'),(N'Sand-Box'),
(N'Sand Box'),(N'Prod'),(N'Product'),(N'Production'),(N'Staging'),(N'Spring'),
(N'Summer'),(N'Fall'),(N'Winter'),(N'Pass'),(N'PWD'),(N'Pword'),(N'Password'),('dbo'),
(N'Pa$$w0rd'),(N'Pa55w0rd');

/* 
	Declare @Symbols table variable to store symbols commonly found in passwords 
*/
DECLARE @Symbols TABLE 
	(
		[Sym] NVARCHAR(1)
	);
/* 
	Populate the @Symbols table variable 
*/
INSERT INTO @Symbols
(Sym)
VALUES
(N'~'),(N'`'),(N'!'),(N'@'),(N'#'),(N'$'),(N'%'),(N'^'),(N'&'),(N'*'),(N'(N'),(N')'),(N'_'),
(N'-'),(N'+'),(N'='),(N'{'),(N'}'),(N'['),(N']'),(N'|'),(N';'),(N':'),(N''''),
(N'"'),(N'<'),(N'>'),(N','),(N'.'),(N'?'),(N'/'),(N'\'),(N''),(N'0'),(N'1'),(N'2'),(N'3'),
(N'4'),(N'5'),(N'6'),(N'7'),(N'8'),(N'9');

/* 
	Populate #CustomPassCombo with user database names and their creation dates
	cross applied with the values in the @CommonTerms table variable 
*/
INSERT INTO #CustomPassCombo
			(
				[InstanceInfo], 
				[CommonTerms], 
				[DatabaseCreated]
			)
SELECT	
	CAST([DB].[name] AS NVARCHAR(52))		AS [InstanceInfo], 
	[CT].[CommTerms]						AS [CommonTerms], 
	CONVERT(VARCHAR,[DB].[create_date],23)	AS [DatabaseCreated]
FROM sys.databases AS [DB]
CROSS APPLY @CommonTerms AS [CT] 
	WHERE [DB].[database_id] > 4

/* 
	Populate #CustomPassCombo with SQL login names and their creation dates
	cross applied with the values in the @CommonTerms table variable 
*/
INSERT INTO #CustomPassCombo
			(
				[InstanceInfo], 
				[CommonTerms], 
				[LoginCreated]
			)
SELECT	
	CAST([SL].[name] AS NVARCHAR(52))		AS [InstanceInfo], 
	[CT].[CommTerms]						AS [CommonTerms], 
	CONVERT(VARCHAR,[SL].[create_date],23)	AS [LoginCreated]
FROM sys.sql_logins AS [SL]
CROSS APPLY @CommonTerms AS [CT] 
	WHERE [SL].[name] NOT LIKE N'##%##'
	AND [SL].[is_disabled] IN (0, @IsDisabled)

END
IF (@UseInstanceInfo=1)
BEGIN
DECLARE @InstanceInfoList NVARCHAR(26);
/* Set @InstanceInfoList */
SELECT @InstanceInfoList = @InstanceName +'_'+ CONVERT(NVARCHAR,GETDATE(),23);
/*
	First pass - Insert only single terms w/ and w/o symbol wrapping into [dbo].[TempCustomPasswords]
*/

	/* 
		Database names wrapped between symbols
	*/
;WITH [PDN] (PrefixDBNames) AS
(
	SELECT DISTINCT([SY].[Sym]+[InstanceInfo])
	FROM #CustomPassCombo AS [DB]
	CROSS APPLY @Symbols AS [SY]
		WHERE [DB].[DatabaseCreated] IS NOT NULL
)
INSERT INTO [dbo].[TempCustomPasswords]
			([Pass],[SourceList])
	SELECT [PDN].[PrefixDBNames]+[SY].[Sym],@InstanceInfoList
	FROM [PDN]
	CROSS APPLY @Symbols AS [SY];

	/* 
		Add the SQL login names wrapped between symbols
	*/
;WITH [PSL] (PrefixSQLLogins) AS
(
	SELECT DISTINCT([SY].[Sym]+[InstanceInfo])
	FROM #CustomPassCombo AS [SL]
	CROSS APPLY @Symbols AS [SY]
		WHERE [SL].[LoginCreated] IS NOT NULL
)
INSERT INTO [dbo].[TempCustomPasswords]
			([Pass], [SourceList])
	SELECT [PSL].[PrefixSQLLogins]+[SY].[Sym],@InstanceInfoList
	FROM [PSL]
	CROSS APPLY @Symbols AS [SY];

	/* 
		Add the instance 
	*/
;WITH [PI] (PrefixInstanceName) AS
(
	SELECT [SY].[Sym]+@InstanceName
	FROM @Symbols AS [SY]
)
INSERT INTO [dbo].[TempCustomPasswords]
			([Pass], [SourceList])
	SELECT [PI].[PrefixInstanceName]+[SY].[Sym], @InstanceInfoList
	FROM [PI]
	CROSS APPLY @Symbols AS [SY];


	/* 
		Add instance creation year month and day 
	*/
		/* 
			without '-' 
		*/
;WITH [PICD] (PrefixInstCreateDate) AS
(
	SELECT [SY].[Sym]+REPLACE(@InstanceCreated,'-','')
	FROM @Symbols AS [SY]
)
INSERT INTO [dbo].[TempCustomPasswords]
			([Pass], [SourceList])
	SELECT [PICD].[PrefixInstCreateDate]+[SY].[Sym], @InstanceInfoList
	FROM [PICD]
	CROSS APPLY @Symbols AS [SY];
		/* 
			with '-'
		*/
;WITH [PICD] (PrefixInstCreateDate) AS
	(
		SELECT [SY].[Sym]+@InstanceCreated
		FROM @Symbols AS [SY]
	)
INSERT INTO [dbo].[TempCustomPasswords]
			([Pass], [SourceList])
	SELECT [PICD].[PrefixInstCreateDate]+[SY].[Sym], @InstanceInfoList
	FROM [PICD]
	CROSS APPLY @Symbols AS [SY];


/*	Second Pass
	Concatenation between values stored in the #CustomPassCombo table 
	(databse, common terms, login names database create date, login create date)
	and other instance-related variables (Instance Create Date, Current Year, Instance Name)
	wrapped between Symbols
*/
;WITH [CustomPassComboConcat] (PrefixCustomPassComboConcat) AS
	(
		/*
		Database names (DatabaseCreated IS NOT NULL) concatenated with Common Terms
		*/
		SELECT	DISTINCT([SY].[Sym]+[InstanceInfo]+[CommonTerms])
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [DatabaseCreated] IS NOT NULL
		/*
			Database names concatenated with _ and Common Terms 
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+[InstanceInfo]+'_'+[CommonTerms])
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [DatabaseCreated] IS NOT NULL
		/*
			Database names concatenated with lowercase Common Terms 
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+[InstanceInfo]+LOWER([CommonTerms]))
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [DatabaseCreated] IS NOT NULL
		/*
			Database names concatenated with _ and lowercase Common Terms 
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+[InstanceInfo]+'_'+LOWER([CommonTerms]))
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [DatabaseCreated] IS NOT NULL
		/*
			Database names concatenated with uppercase Common Terms 
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+[InstanceInfo]+UPPER([CommonTerms]))
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [DatabaseCreated] IS NOT NULL
		/*
			Database names concatenated with _ and uppercase Common Terms 
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+[InstanceInfo]+'_'+UPPER([CommonTerms]))
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [DatabaseCreated] IS NOT NULL
		/* 
			Uppercase Common Terms concatenated with @ and Database Names  
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+UPPER([CommonTerms])+'@'+[InstanceInfo] )
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [DatabaseCreated] IS NOT NULL
		/* 
			Lowercase Common Terms concatenated with @ and Database Names  
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+LOWER([CommonTerms])+'@'+[InstanceInfo] )
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [DatabaseCreated] IS NOT NULL
		/* 
			Common Terms concatenated with @ and Database Names  
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+[CommonTerms]+'@'+[InstanceInfo] )
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [DatabaseCreated] IS NOT NULL
		/* 
			Common Terms concatenated with Database Names  
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+[CommonTerms]+[InstanceInfo] )
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [DatabaseCreated] IS NOT NULL
		/* 
			Database Name concatenated with @CurrentYear
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+[InstanceInfo]+@CurrentYear)
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [DatabaseCreated] IS NOT NULL
		/*
			Database name concatenated with database creation year
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+[InstanceInfo]+CAST([DatabaseCreated] AS VARCHAR(4)))
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [DatabaseCreated] IS NOT NULL
		/*
			Login name concatenated with login creation year
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+[InstanceInfo]+CAST([LoginCreated] AS VARCHAR(4))) 
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [LoginCreated] IS NOT NULL
		/*
			@InstanceName concatenated with @InstanceCreated Year
		*/
		UNION 
		SELECT [SY].[Sym]+@InstanceName+CAST(@InstanceCreated AS VARCHAR(4))
		FROM @Symbols AS [SY]
		/*
			@InstanceName concatenated with @InstanceCreated w/o -
		*/
		UNION 
		SELECT [SY].[Sym]+@InstanceName+REPLACE(@InstanceCreated,'-','')
		FROM @Symbols AS [SY]
		/*
			Instance name concatenated with common terms
		*/
		UNION 
		SELECT DISTINCT([SY].[Sym]+@InstanceName+[CommonTerms])
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
	)
	/*
		Add symbols to the end of the combinations 
		from [CustomPassComboConcat] and insert them into the table
	*/
	INSERT INTO [dbo].[TempCustomPasswords]
				([Pass], [SourceList])
	SELECT [CPCC].[PrefixCustomPassComboConcat]+[SY].[Sym], @InstanceInfoList
	FROM [CustomPassComboConcat] AS [CPCC]
	CROSS APPLY @Symbols AS [SY];

END

	/*	Combinations with @CustomTerm if provided */

IF (@CustomTerm <> N'')
BEGIN
/* Declare CustomTermList */
DECLARE @CustomTermList NVARCHAR(42);
/* Set @CustomTermList */
SET @CustomTermList = @CustomTerm+'_'+ CONVERT(NVARCHAR,GETDATE(),23);
;WITH [CustomTermCombos]  ([PrefixCustTermCombos]) AS
(		/*
			CustomTerm only
		*/
		SELECT [SY].[Sym]+@CustomTerm
		FROM @Symbols AS [SY]
		/*
			@CustomTerm concatenated with @CurrentYear 
		*/
		UNION
		SELECT	[SY].[Sym]+@CustomTerm+@CurrentYear
		FROM @Symbols AS [SY]
		/*
			@CustomTerm concatenated with @CurrentYear-1
		*/
		UNION
		SELECT	[SY].[Sym]+@CustomTerm+CAST(CONVERT(VARCHAR,DATEADD(YEAR,-1,GETDATE()),23) AS VARCHAR(4))
		FROM @Symbols AS [SY]
		/*
			@CustomTerm concatenated with @CurrentYear-2
		*/
		UNION
		SELECT	[SY].[Sym]+@CustomTerm+CAST(CONVERT(VARCHAR,DATEADD(YEAR,-2,GETDATE()),23) AS VARCHAR(4))
		FROM @Symbols AS [SY]
		/*
			@CustomTerm concatenated with @CurrentYear-3
		*/
		UNION
		SELECT	[SY].[Sym]+@CustomTerm+CAST(CONVERT(VARCHAR,DATEADD(YEAR,-3,GETDATE()),23) AS VARCHAR(4))
		FROM @Symbols AS [SY]

		/*
			Lazy l33t on @CustomTerm - the most common l33t-style replacements 
			concatenated with @CurrentYear 
		*/
		UNION
		SELECT	[SY].[Sym]+REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@CustomTerm,'e','3'),'a','@'),'o','0'),'i','1'),'E','3'),'A','4'),'O','0'),'I','1')+@CurrentYear
		FROM @Symbols AS [SY]
		UNION
		SELECT	[SY].[Sym]+REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@CustomTerm,'e','3'),'a','4'),'o','0'),'i','1'),'E','3'),'A','4'),'O','0'),'I','1')+@CurrentYear
		FROM @Symbols AS [SY]
		/*
			Lazy l33t on @CustomTerm - the most common l33t-style replacements 
			concatenated with @CurrentYear-1 
		*/
		UNION
		SELECT	[SY].[Sym]+REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@CustomTerm,'e','3'),'a','@'),'o','0'),'i','1'),'E','3'),'A','@'),'O','0'),'I','1')+CAST(CONVERT(VARCHAR,DATEADD(YEAR,-1,GETDATE()),23) AS VARCHAR(4))
		FROM @Symbols AS [SY]
		UNION
		SELECT	[SY].[Sym]+REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@CustomTerm,'e','3'),'a','4'),'o','0'),'i','1'),'E','3'),'A','4'),'O','0'),'I','1')+CAST(CONVERT(VARCHAR,DATEADD(YEAR,-1,GETDATE()),23) AS VARCHAR(4))
		FROM @Symbols AS [SY]
		/*
			Lazy l33t on @CustomTerm - the most common l33t-style replacements 
			concatenated with @CurrentYear-2 
		*/
		UNION
		SELECT	[SY].[Sym]+REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@CustomTerm,'e','3'),'a','@'),'o','0'),'i','1'),'E','3'),'A','@'),'O','0'),'I','1')+CAST(CONVERT(VARCHAR,DATEADD(YEAR,-2,GETDATE()),23) AS VARCHAR(4))
		FROM @Symbols AS [SY]
		UNION
		SELECT	[SY].[Sym]+REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@CustomTerm,'e','3'),'a','4'),'o','0'),'i','1'),'E','3'),'A','4'),'O','0'),'I','1')+CAST(CONVERT(VARCHAR,DATEADD(YEAR,-2,GETDATE()),23) AS VARCHAR(4))
		FROM @Symbols AS [SY]
		/*
			Lazy l33t on @CustomTerm - the most common l33t-style replacements 
			concatenated with @CurrentYear-3 
		*/
		UNION
		SELECT	[SY].[Sym]+REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@CustomTerm,'e','3'),'a','@'),'o','0'),'i','1'),'E','3'),'A','@'),'O','0'),'I','1')+CAST(CONVERT(VARCHAR,DATEADD(YEAR,-3,GETDATE()),23) AS VARCHAR(4))
		FROM @Symbols AS [SY]
		UNION
		SELECT	[SY].[Sym]+REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@CustomTerm,'e','3'),'a','4'),'o','0'),'i','1'),'E','3'),'A','4'),'O','0'),'I','1')+CAST(CONVERT(VARCHAR,DATEADD(YEAR,-3,GETDATE()),23) AS VARCHAR(4))
		FROM @Symbols AS [SY]
		/*
			Database Name concatenated with @CustomTerm 
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+[InstanceInfo]+@CustomTerm)
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [DatabaseCreated] IS NOT NULL
		/*
			Database Name concatenated with @CustomTerm and Current Year
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+[InstanceInfo]+@CustomTerm+@CurrentYear)
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [DatabaseCreated] IS NOT NULL
		/*
			Database Name concatenated with @CustomTerm and Database Creation Year
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+[InstanceInfo]+@CustomTerm+CAST([DatabaseCreated] AS VARCHAR(4)))
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [DatabaseCreated] IS NOT NULL
		/*
			Login Name concatenated with @CustomTerm
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+[InstanceInfo]+@CustomTerm)
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [LoginCreated] IS NOT NULL
		/*
			Login Name concatenated with @CustomTerm and Current Year
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+[InstanceInfo]+@CustomTerm+@CurrentYear)
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [LoginCreated] IS NOT NULL
		/*
			Login Name concatenated with @CustomTerm and Login Creation Year
		*/
		UNION
		SELECT	DISTINCT([SY].[Sym]+[InstanceInfo]+@CustomTerm+CAST([LoginCreated] AS VARCHAR(4)))
		FROM #CustomPassCombo
		CROSS APPLY @Symbols AS [SY]
			WHERE [LoginCreated] IS NOT NULL
		/*
			@InstanceName concatenated with @CustomTerm
		*/
		UNION 
		SELECT [SY].[Sym]+@InstanceName+@CustomTerm
		FROM @Symbols AS [SY]
		/*
			@InstanceName concatenated with @CustomTerm and @InstanceCreated Year
		*/
		UNION 
		SELECT [SY].[Sym]+@InstanceName+@CustomTerm+CAST(@InstanceCreated AS VARCHAR(4))
		FROM @Symbols AS [SY]
		/*
			@InstanceName concatenated with @CustomTerm and @InstanceCreated Year Month without '-'
		*/
		UNION
		SELECT [SY].[Sym]+@InstanceName+@CustomTerm+REPLACE(CAST(@InstanceCreated AS VARCHAR(7)),'-','')
		FROM @Symbols AS [SY]
		/*
			@InstanceName concatenated with @CustomTerm and @InstanceCreated Year Month Day without '-'
		*/
		UNION
		SELECT [SY].[Sym]+@InstanceName+@CustomTerm+REPLACE(CAST(@InstanceCreated AS VARCHAR(10)),'-','')
		FROM @Symbols AS [SY]
)
	INSERT INTO [dbo].[TempCustomPasswords]
				([Pass],[SourceList])
	SELECT [CTC].[PrefixCustTermCombos]+[SY].[Sym], @CustomTermList
	FROM [CustomTermCombos] AS [CTC]
	CROSS APPLY @Symbols AS [SY];
END;



/* Handle Source Lists */
  IF (@SourceLists = N'ALL')
  BEGIN
 INSERT INTO #SelectedLists ([ListName],[Selected])
 SELECT DISTINCT([SourceList]), 1 FROM [dbo].[Passwords];
  END;
  ELSE IF (@SourceLists <> N'ALL')
  BEGIN
  SET @SourceLists = REPLACE(@SourceLists, CHAR(10), N'');
  SET @SourceLists = REPLACE(@SourceLists, CHAR(13), N'');
  WHILE CHARINDEX(@Delim + ' ', @SourceLists) > 0 
	SET @SourceLists = REPLACE(@SourceLists, @Delim + N' ', @Delim);
  WHILE CHARINDEX(N' ' + @Delim, @SourceLists) > 0 
	SET @SourceLists = REPLACE(@SourceLists, N' ' + @Delim, @Delim);

  SET @SourceLists = LTRIM(RTRIM(@SourceLists));

  WITH Lists1 (StartPosition, EndPosition, ListItem) AS
  (
  SELECT 1 AS StartPosition,
         ISNULL(NULLIF(CHARINDEX(@Delim, @SourceLists, 1), 0), LEN(@SourceLists) + 1) AS EndPosition,
         SUBSTRING(@SourceLists, 1, ISNULL(NULLIF(CHARINDEX(@Delim, @SourceLists, 1), 0), LEN(@SourceLists) + 1) - 1) AS ListItem
  WHERE @SourceLists IS NOT NULL
  UNION ALL
  SELECT CAST(EndPosition AS int) + 1 AS StartPosition,
         ISNULL(NULLIF(CHARINDEX(@Delim, @SourceLists, EndPosition + 1), 0), LEN(@SourceLists) + 1) AS EndPosition,
         SUBSTRING(@SourceLists, EndPosition + 1, ISNULL(NULLIF(CHARINDEX(@Delim, @SourceLists, EndPosition + 1), 0), LEN(@SourceLists) + 1) - EndPosition - 1) AS ListItem
  FROM Lists1
  WHERE EndPosition < LEN(@SourceLists) + 1
  ),
  Lists2 (ListName, StartPosition, Selected) AS
  (
  SELECT CASE WHEN ListItem LIKE N'-%' THEN RIGHT(ListItem,LEN(ListItem) - 1) ELSE ListItem END AS ListItem,
         StartPosition,
         CASE WHEN ListItem LIKE N'-%' THEN 0 ELSE 1 END AS Selected
  FROM Lists1
  )
  INSERT INTO #SelectedLists (ListName,StartPosition, Selected)
  SELECT ListName,
         StartPosition,
         Selected
  FROM Lists2
  OPTION (MAXRECURSION 0)
  END


IF (@ResultsToTable = 1)
BEGIN 
 IF NOT EXISTS  (SELECT * FROM sys.objects 
	WHERE [object_id] = OBJECT_ID(N'[dbo].[SQLAuditResults]') AND [type] in (N'U'))
	BEGIN
		CREATE TABLE [dbo].[SQLAuditResults]
		(
			[ID] INT IDENTITY(1,1) PRIMARY KEY CLUSTERED NOT NULL,
			[LoginName] SYSNAME,
			[Password] NVARCHAR(128),
			[FromSourceList] NVARCHAR(128)
		);
	END
INSERT INTO [dbo].[SQLAuditResults] 
			(
				[LoginName],
				[Password],
				[FromSourceList]			
			)
SELECT	[SL].[name]			AS [LoginName],
		[P].[Pass]			AS [Password],
		[P].[SourceList]	AS [FromSourceList]
FROM sys.sql_logins AS [SL]
INNER JOIN [dbo].[Passwords] AS [P]
	ON PWDCOMPARE([P].[Pass],[SL].[password_hash]) = 1
WHERE
  /* Filtering based on @IgnorePolicy */
	(
		(
			[SL].[is_policy_checked] = 1 
		AND LEN([P].[Pass])>=8
		)
	OR 
		(
			[SL].[is_policy_checked] IN (0, @IgnorePolicy) 
		AND LEN([P].[Pass])>=0
		)
	)
	/* Filtering based on @IsDisabled (@ExcludeDisabled) */
	AND	[SL].[is_disabled] IN (0, @IsDisabled)
	/* Filtering source lists*/
	AND [P].[SourceList] IN (SELECT [ListName] 
							FROM #SelectedLists)
	/* Filter out certificate-based accounts */
	AND [SL].[name] NOT LIKE N'##%##'
UNION 
SELECT	[SL].[name]			AS [LoginName],
		[TP].[Pass]			AS [Password],
		[TP].[SourceList]	AS [FromSourceList]
FROM sys.sql_logins AS [SL]
INNER JOIN [dbo].[TempCustomPasswords] AS [TP]
ON PWDCOMPARE([TP].[Pass],[SL].[password_hash]) = 1
WHERE
  /* Filtering based on @IgnorePolicy */
	(
		(
			[SL].[is_policy_checked] = 1 
		AND LEN([TP].[Pass])>=8
		)
	OR 
		(
			[SL].[is_policy_checked] IN (0, @IgnorePolicy) 
		AND LEN([TP].[Pass])>=0
		)
	)
	/* Filtering based on @IsDisabled (@ExcludeDisabled) */
	AND	[SL].[is_disabled] IN (0, @IsDisabled)
	/* Filter out certificate-based accounts */
	AND [SL].[name] NOT LIKE N'##%##';
END;
ELSE IF (@ResultsToTable = 0)
BEGIN
SELECT	[SL].[name]			AS [LoginName],
		[P].[Pass]			AS [Password],
		[P].[SourceList]	AS [FromSourceList]
FROM sys.sql_logins AS [SL]
INNER JOIN [dbo].[Passwords] AS [P]
	ON PWDCOMPARE([P].[Pass],[SL].[password_hash]) = 1
WHERE
  /* Filtering based on @IgnorePolicy */
	(
		(
			[SL].[is_policy_checked] = 1 
		AND LEN([P].[Pass])>=8
		)
	OR 
		(
			[SL].[is_policy_checked] IN (0, @IgnorePolicy) 
		AND LEN([P].[Pass])>=0
		)
	)
	/* Filtering based on @IsDisabled (@ExcludeDisabled) */
	AND	[SL].[is_disabled] IN (0, @IsDisabled)
	/* Filtering source lists */
	AND [P].[SourceList] IN (SELECT [ListName] 
							FROM #SelectedLists)
	/* Filter out certificate-based accounts */
	AND [SL].[name] NOT LIKE N'##%##'
	/* Union with instance-specific and/or custom term based check */
UNION 
SELECT	[SL].[name]			AS [LoginName],
		[TP].[Pass]			AS [Password],
		[TP].[SourceList]	AS [FromSourceList]
FROM sys.sql_logins AS [SL]
INNER JOIN [dbo].[TempCustomPasswords] AS [TP]
ON PWDCOMPARE([TP].[Pass],[SL].[password_hash]) = 1
WHERE
  /*Filtering based on @IgnorePolicy */
	(
		(
			[SL].[is_policy_checked] = 1 
		AND LEN([TP].[Pass])>=8
		)
	OR 
		(
			[SL].[is_policy_checked] IN (0, @IgnorePolicy) 
		AND LEN([TP].[Pass])>=0
		)
	)
	/*Filtering based on @IsDisabled (@ExcludeDisabled)*/
	AND	[SL].[is_disabled] IN (0, @IsDisabled)
	/*Filter out certificate-based accounts*/
	AND [SL].[name] NOT LIKE N'##%##';
END;

/* Clean up */

  IF OBJECT_ID(N'tempdb..#CustomPassCombo') IS NOT NULL
	BEGIN
			DROP TABLE #CustomPassCombo;
	END;
  IF OBJECT_ID(N'tempdb..#SelectedLists') IS NOT NULL
	BEGIN
			DROP TABLE #SelectedLists;
	END;
IF EXISTS(SELECT * FROM sys.objects 
		WHERE [object_id] = OBJECT_ID(N'[dbo].[TempCustomPasswords]') AND [type] in (N'U'))
	BEGIN
		DROP TABLE [dbo].[TempCustomPasswords];
	END;
IF (@UseInstanceInfo=1 OR @CustomTerm <> N'')
BEGIN
	IF EXISTS(SELECT [OB].[name], SUM([PT].[rows])
				FROM sys.objects AS [OB]
				INNER JOIN sys.partitions [PT]
				ON [OB].[object_id] = [PT].[object_id]
					WHERE [OB].[object_id] = OBJECT_ID(N'[dbo].[Passwords]') AND [type] in (N'U')
					GROUP BY [OB].[name] HAVING(SUM([PT].[rows])= 0))
	BEGIN
	DROP TABLE [dbo].[Passwords];
	END;
END; 
