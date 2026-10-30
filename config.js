/* EDIT THIS FILE after creating your Supabase project (see README-TH.md).
   Everything here is PUBLIC by design. The publishable key is safe in a web page because the database rules
   (supabase-setup.sql) decide what each user may do. NEVER put a secret / service_role key here. */
window.CDE_CONFIG={
  prod:true,
  captcha:{ sitekey:'' },                   // Cloudflare Turnstile SITE key (public). Leave '' = captcha off. The SECRET key goes only in Supabase.
  legal:{                                   // shown in the Privacy Policy and Terms (PDPA) – fill in BEFORE public launch
    operator:'ภานุชิต ผลาน้อย (Phanuchit Phlanoi)',                            // legal name of the person/company running the app
    contact:'phanu.chita2522@gmail.com',                             // email or phone for privacy requests (public)
    address:'55/865 หมู่ 3 หมู่บ้านศุภาลัย ไพรด์ บางนา-ลาดกระบัง ตำบลศีรษะจรเข้น้อย อำเภอบางเสาธง จังหวัดสมุทรปราการ 10570',                             // postal address
    region:'Tokyo, Japan (Supabase ap-northeast-1)'                               // where the database is hosted, e.g. 'Singapore' (shown in Supabase project settings)
  }
};
window.CDE_SUPABASE={url:'https://mzwauorhbylavfilrssx.supabase.co',key:'sb_publishable_qe6mXO9LZkUH0VcqMwJwdg_6IsROc8r'};
