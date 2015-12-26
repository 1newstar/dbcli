local db,cfg=env.oracle,env.set
local sqlprof={}
function sqlprof.extract_profile(sql_id,sql_plan,sql_text)
    local stmt=[[
    DECLARE
        v_SQL CLOB:=:1;
        PROCEDURE extract_profile(p_buffer     OUT CLOB,
                                  p_sqlid      VARCHAR2,
                                  p_plan       VARCHAR2 := NULL,
                                  p_forcematch BOOLEAN := true) IS
            /*
            To generate the script to fix the execution plan with SQL profile
            Parameters:
              p_sqlid: The target SQL to be fixed, can be SQL_ID/SQL Profile name/SPM plan name
              p_plan:  The exec plan to be used, can be:
                          a.Plan_hash_value of target SQL, when null then use the default plan
                          b.Another optimized SQL's sql id/SQL Profile name/SPM plan name
                       For the "b" option, the 2 SQLs have be of the same text except hints
            Examples:
               1) Extract profile from specifc execution plan:
                  exec extract_profile('dc5n1gqgfq09h',3273999458);
               2) Extract profile from another optimized sql as the replacement of target SQL:
                  exec extract_profile('dc5n1gqgfq09h','dc5n1gqgfq09s');
               3) Extract profile from SPM for target SQL:
                  exec extract_profile('SQL_PLAN_004szdq6gtbrtc3254462');
               4) Extract profile from SPM of another optimized SQL to target sql:
                  exec extract_profile('dc5n1gqgfq09h','SQL_PLAN_004szdq6gtbrtc3254462');
               4) Extract profile from plan_table, make sure there is only one statement in the plan table:
                  exec extract_profile('dc5n1gqgfq09h','plan');
            */
            v_signatrue   INT;
            v_source      VARCHAR2(100);
            v_plan_source VARCHAR2(50);
            v_hints       xmltype;
            v_hint        VARCHAR2(32767);
            v_text        CLOB;
            v_pos         PLS_INTEGER;
            v_size        PLS_INTEGER;
            PROCEDURE get_sql(p_sqlid VARCHAR2) IS
            BEGIN
                SELECT REPLACE(sql_text, chr(0), ' '), src
                INTO   v_sql, v_source
                FROM   (
                        --awr and sqlset
                        SELECT SQL_TEXT,  p_sqlid src
                        FROM   dba_hist_sqltext a
                        WHERE  sql_id = p_sqlid
                        UNION ALL
                        SELECT SQL_FULLTEXT, p_sqlid
                        FROM   gv$sql a
                        WHERE  sql_id = p_sqlid
                    $IF DBMS_DB_VERSION.VERSION>10  $THEN
                        UNION ALL
                        SELECT SQL_TEXT,
                                decode(b.obj_type, 1, p_sqlid, 2,  substr(p_sqlid, -26)) src
                        FROM   sys.sqlobj$ b, sys.sql$text a
                        WHERE  b.name = p_sqlid
                        AND    b.signature = a.signature
                    $ELSE
                        UNION ALL
                        SELECT SQL_TEXT, p_sqlid src
                        FROM   sys.sqlprof$ b, sys.sql$text a
                        WHERE  b.sp_name = p_sqlid
                        AND    b.signature = a.signature
                    $END)
                WHERE  rownum < 2;
            END;

            PROCEDURE get_plan(p_sql_id varchar2) IS
                v_plan VARCHAR2(30);
            BEGIN
                v_plan := CASE
                              WHEN p_plan IS NULL THEN '%'
                              WHEN upper(p_plan) IN('PLAN','PLAN_TABLE') then '-1'
                              ELSE nvl(regexp_substr(p_plan, '^\d+$'), 'z') || '%'
                          END;
                SELECT xmltype(other_xml), src
                INTO   v_hints, v_plan_source
                FROM   (
                    SELECT /*+no_expand*/
                         other_xml, src
                        FROM   (SELECT other_xml, 'awr' src, sql_id, plan_hash_value
                                FROM   dba_hist_sql_plan a
                                UNION ALL
                                SELECT other_xml, 'sqlset', sql_id, plan_hash_value
                                FROM   dba_sqlset_plans a
                                UNION ALL
                                SELECT other_xml, 'memory', sql_id, plan_hash_value
                                FROM   gv$sql_plan a
                                UNION ALL
                                SELECT other_xml, 'plan table', p_sql_id sql_id, -1
                                FROM   PLAN_TABLE a)
                        WHERE  rownum < 2
                        AND    (sql_id = p_sqlid AND plan_hash_value LIKE v_plan OR sql_id = p_plan OR src='plan table' and sql_id='_x_')
                        AND    other_xml IS NOT NULL
                    $IF DBMS_DB_VERSION.VERSION>10 $THEN
                        UNION ALL
                        SELECT comp_data, decode(b.obj_type, 1, 'profile', 'spm') src
                        FROM   sys.sqlobj$ b, sys.sqlobj$data a
                        WHERE  b.name = nvl(p_plan, p_sqlid)
                        AND    b.signature = a.signature
                    $ELSE
                        UNION ALL
                        SELECT Xmlelement("outline_data", xmlagg(Xmlelement("hint", attr_val) ORDER BY attr#))
                               .getclobval() comp_data,
                               'profile' src
                        FROM   sys.sqlprof$ b, sys.sqlprof$attr a
                        WHERE  b.sp_name = nvl(p_plan, p_sqlid)
                        AND    b.signature = a.signature
                    $END)
                WHERE  rownum < 2;
            EXCEPTION
                WHEN no_data_found THEN
                    raise_application_error(-20001, 'Cannot find hints for the execution plan!');
            END;

            PROCEDURE pr(p_text VARCHAR2, flag BOOLEAN DEFAULT TRUE) IS
            BEGIN
                IF flag THEN
                    dbms_lob.writeappend(v_text, lengthb(p_text) + 1, p_text || chr(10));
                ELSE
                    dbms_lob.writeappend(v_text, lengthb(p_text), p_text);
                END IF;
            END;
        BEGIN
            dbms_output.enable(NULL);
            IF v_sql IS NULL THEN 
                BEGIN
                    get_sql(p_sqlid);
                EXCEPTION WHEN NO_DATA_FOUND THEN
                    p_buffer:='#Cannot find SQL text for '||p_sqlid||'!';
                    return;
                END;
            END IF;
            get_plan(case when upper(p_plan) IN('PLAN','PLAN_TABLE') then '_x_' end);
            dbms_lob.createtemporary(v_text, TRUE);
            pr('Set define off sqlbl on'||chr(10));
            pr('DECLARE');
            pr('    sql_txt   CLOB;');
            pr('    sql_prof  SYS.SQLPROF_ATTR;');
            pr('    signature NUMBER;');
            pr('    procedure wr(x varchar2) is begin dbms_lob.writeappend(sql_txt, lengthb(x), x);end;');
            pr('BEGIN');
            v_size := length(v_sql);
            IF v_size <= 1200 OR dbms_lob.instr(v_sql, CHR(10)) > 0 THEN
                pr('    sql_txt := q''[', FALSE);
                dbms_lob.append(v_text, v_sql);
                pr(']'';');
            ELSE
                pr('    dbms_lob.createtemporary(sql_txt, TRUE);');
                v_pos := 0;
                WHILE TRUE LOOP
                    pr('    wr(q''[' || dbms_lob.substr(v_sql, 1000, v_pos * 1000 + 1) || ']'');');
                    v_pos  := v_pos + 1;
                    v_size := v_size - 1000;
                    EXIT WHEN v_size < 1;
                END LOOP;
            END IF;
            pr('    ');
            v_signatrue := dbms_sqltune.SQLTEXT_TO_SIGNATURE(v_sql, TRUE);
            IF p_plan IS NOT NULL AND NOT regexp_like(p_plan, '^\d+$') AND upper(p_plan) NOT IN('PLAN','PLAN_TABLE') THEN
                v_sql       := regexp_replace(v_sql, '/\*.*?\*/');
                BEGIN
                    get_sql(p_plan);
                EXCEPTION WHEN NO_DATA_FOUND THEN
                    p_buffer:='#Cannot find SQL text for '||p_plan||'!';
                    return;
                END;
                v_sql := regexp_replace(v_sql, '/\*.*?\*/');
                IF v_signatrue != dbms_sqltune.SQLTEXT_TO_SIGNATURE(v_sql, TRUE) THEN
                    pr('    --! Warning: Signatures for the 2 SQLs are not matched!');
                END IF;
            END IF;
            pr('    sql_prof := SYS.SQLPROF_ATTR(');
            pr('        q''[BEGIN_OUTLINE_DATA]'',');
            FOR i IN (SELECT /*+ opt_param('parallel_execution_enabled', 'false') */
                             SUBSTR(EXTRACTVALUE(VALUE(d), '/hint'), 1, 4000) hint
                      FROM   TABLE(XMLSEQUENCE(EXTRACT(v_hints, '//outline_data/hint'))) d) LOOP
                v_hint := i.hint;
                WHILE NVL(LENGTH(v_hint), 0) > 0 LOOP
                    IF LENGTH(v_hint) <= 500 THEN
                        pr('        q''[' || v_hint || ']'',');
                        v_hint := NULL;
                    ELSE
                        v_pos := INSTR(SUBSTR(v_hint, 1, 500), ' ', -1);
                        pr('        q''[' || SUBSTR(v_hint, 1, v_pos) || ']'',');
                        v_hint := '   ' || SUBSTR(v_hint, v_pos);
                    END IF;
                END LOOP;
            END LOOP;

            v_source:= 'PROF_'||nvl(v_source,to_char(v_signatrue,'fm'||rpad('X',length(v_signatrue),'X')));

            pr('        q''[END_OUTLINE_DATA]'');');
            pr('    signature := DBMS_SQLTUNE.SQLTEXT_TO_SIGNATURE(sql_txt);');
            pr('    DBMS_SQLTUNE.IMPORT_SQL_PROFILE (');
            pr('        sql_text    => sql_txt,');
            pr('        profile     => sql_prof,');
            pr('        name        => ''' || v_source || ''',');
            pr('        description => ''' || v_source || '_''||signature,');
            pr('        category    => ''DEFAULT'',');
            pr('        validate    => TRUE,');
            pr('        replace     => TRUE,');
            pr('        force_match => ' || CASE WHEN p_forcematch THEN 'TRUE' ELSE 'FALSE' END || ');');
            pr('    --To drop this profile, execute: DBMS_SQLTUNE.DROP_SQL_PROFILE('''||v_source||''')');
            pr('END;');
            pr('/');
            p_buffer := v_text;

            
        END;
    BEGIN
        extract_profile(:2,:3,:4, TRUE);
    END;]]
    env.checkhelp(sql_id or sql_text)
    if not db:check_access('sys.sql$text',1) then
        stmt=stmt:gsub("%$IF.-%$END","")
    end
    local args={sql_text or "",'#CLOB',sql_id or "",sql_plan or ""}
    db:internal_call(stmt,args)
    if args[1] and args[1]:sub(1,1)=="#" then
        env.raise(args[1]:sub(2))
    end
    print("Result written to file "..env.write_cache((sql_id or "prof_plan_table")..".sql",args[2]))
end

function sqlprof.onload()
    local help=[[
    Extract sql profile. Usage: sqlprof <sql_id|sql_prof_name|spm_plan_name> [<plan_hash_value|new_sql_id|sql_prof_name|spm_plan_name>|plan]
    The command will not make any changes on the database, but to create a SQL file that used to fix the execution plan by SQL Profile.
    Examples:
        1). Generate the profile for the last plan of target SQL ID: sqlprof gjm43un5cy843
        2). Generate the profile of the specifc SQL ID + plan hash value: sqlprof gjm43un5cy843 1106594730
        3). Generate the profile for a SQL id with the plan of another SQL: sqlprof gjm43un5cy843 53c2k4c43zcfx
        4). Extract an existing SQL profile or baseline: sqlprof PROF_gjm43un5cy843
        5). Generate the profile for a SQL id with the profile/baseline of another sql: sqlprof gjm43un5cy843  PROF_53c2k4c43zcfx
        6). Generate the profile from plan table:
                xplan select * from dual;
                sqlprof gjm43un5cy843 plan;
    ]]
    env.set_command(nil,"sqlprof",help,sqlprof.extract_profile,false,3)
end
return sqlprof