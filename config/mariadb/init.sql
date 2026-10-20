###############################################################################
## Default MySQL tables for autentication purposes within the framework
## Safe to re-run, existing tables and data are kept (see auth_tables_reset.sql)
## User names are case-sensitive (utf8mb4_bin), so 'Alice' and 'alice' are different users.

CREATE TABLE IF NOT EXISTS `sanic_info` (
  `user` VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  `fullname` VARCHAR(250) NULL,
  `department` VARCHAR(250) NULL,
  `apikey` VARCHAR(99) NULL,
  `apikey_created` DATETIME NULL,
  `apikey_expires` DATETIME NULL,
  CONSTRAINT PK_sanic_info PRIMARY KEY (user),
  KEY idx_sanic_info_apikey (apikey)
);

CREATE TABLE IF NOT EXISTS `sanic_access` (
  `user` VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  `access` VARCHAR(250) NOT NULL,
  `value` VARCHAR(250) NOT NULL,
  CONSTRAINT PK_sanic_access PRIMARY KEY (user, access, value),
  CONSTRAINT FK_sanic_access_user FOREIGN KEY(user)
   REFERENCES sanic_info (user)
   ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE IF NOT EXISTS `sanic_challenge` (
  `user` VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  `expect` VARCHAR(250) NOT NULL,
  `attempts` INT DEFAULT 0,
  `sent` DATETIME DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT PK_sanic_challenge PRIMARY KEY (user),
  CONSTRAINT FK_sanic_challenge_user FOREIGN KEY(user)
   REFERENCES sanic_info (user)
   ON DELETE CASCADE ON UPDATE CASCADE
);
