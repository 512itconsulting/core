SET SERVEROUTPUT ON
SET FEEDBACK OFF
SET HEADING OFF
WHENEVER SQLERROR EXIT FAILURE

PROMPT Running serialize_version_f bounds checks

DECLARE
   PROCEDURE expect_success(ip_version IN VARCHAR, ip_expected IN INTEGER)
   IS
      l_actual INTEGER;
   BEGIN
      l_actual := pkg_application.serialize_version_f(ip_version);

      IF l_actual != ip_expected THEN
         raise_application_error(-20000, ip_version||' returned '||l_actual||', expected '||ip_expected);
      END IF;

      dbms_output.put_line('PASS success '||ip_version||' => '||l_actual);
   END;

   PROCEDURE expect_failure(ip_version IN VARCHAR)
   IS
      l_actual INTEGER;
   BEGIN
      l_actual := pkg_application.serialize_version_f(ip_version);
      raise_application_error(-20000, ip_version||' unexpectedly returned '||l_actual);
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLERRM NOT LIKE '%Assertion Error:%' THEN
            RAISE;
         END IF;

         dbms_output.put_line('PASS failure '||ip_version||' => '||SQLERRM);
   END;
BEGIN
   expect_success('1.2.3', 100020003);
   expect_success('9999.9999.9999', 999999999999);
   expect_failure('10000.0.0');
   expect_failure('1.10000.0');
   expect_failure('1.2.10000');
END;
/

EXIT SUCCESS
