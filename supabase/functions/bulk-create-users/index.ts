// supabase/functions/bulk_create_users/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

serve(async (req) => {
  try {
    // ✅ Admin secret header protection (REQUIRED)
    const expectedSecret = Deno.env.get("BULK_CREATE_SECRET");
    const providedSecret = req.headers.get("x-bulk-secret");

    if (!expectedSecret || !providedSecret || providedSecret !== expectedSecret) {
      return new Response(
        JSON.stringify({ ok: false, error: "Unauthorized" }),
        { status: 401, headers: { "Content-Type": "application/json" } },
      );
    }

    // Optional: only allow POST
    if (req.method !== "POST") {
      return new Response(
        JSON.stringify({ ok: false, error: "Method not allowed" }),
        { status: 405, headers: { "Content-Type": "application/json" } },
      );
    }

    // Fixed temp password (change if needed)
    const DEFAULT_PASSWORD = "#1234@Test!";

    // ✅ Your users list (email + password)
    const users: { email: string; password: string }[] = [
      { email: "eman.elsaim@qparts.co", password: DEFAULT_PASSWORD },
      { email: "mchengaruth@petromin.com", password: DEFAULT_PASSWORD },
      { email: "junaid19655@gmail.com", password: DEFAULT_PASSWORD },
      { email: "hassan.magdy@qparts.co", password: DEFAULT_PASSWORD },
      { email: "faisal.akram@petromin.com", password: DEFAULT_PASSWORD },
      { email: "amer.aljabari@petromin.com", password: DEFAULT_PASSWORD },
      { email: "mohammed.alossaimi@shaheen-alarabia.com", password: DEFAULT_PASSWORD },
      { email: "abdullah.nadeem@petromin.com", password: DEFAULT_PASSWORD },
      { email: "jeffrey.d@petromin.com", password: DEFAULT_PASSWORD },
      { email: "ahmed.jamali@petromin.com", password: DEFAULT_PASSWORD },
      { email: "imad.shahzad@petromin.com", password: DEFAULT_PASSWORD },
      { email: "mohamed.salah@qparts.co", password: DEFAULT_PASSWORD },
      { email: "mohamad.hamdan@limarcenter.com", password: DEFAULT_PASSWORD },
      { email: "abdualmuneim@qparts.co", password: DEFAULT_PASSWORD },
      { email: "joud.fakoush@petromin.com", password: DEFAULT_PASSWORD },
      { email: "turbocare27@gmail.com", password: DEFAULT_PASSWORD },
      { email: "peerkhantaukeerraza@gmail.com", password: DEFAULT_PASSWORD },
      { email: "m.bata@petromin.com", password: DEFAULT_PASSWORD },
      { email: "tech-dream@hotmail.com", password: DEFAULT_PASSWORD },
      { email: "workshop@gmail.com", password: DEFAULT_PASSWORD },
      { email: "baraa.badreldin@qparts.co", password: DEFAULT_PASSWORD },
      { email: "info@carshubksa.com", password: DEFAULT_PASSWORD },
      { email: "mahmoud.z@petromin.com", password: DEFAULT_PASSWORD },
      { email: "b.padia@petromin.com", password: DEFAULT_PASSWORD },
      { email: "gulam.hussain@petromin.com", password: DEFAULT_PASSWORD },
      { email: "ashwin.kumar@petromin.com", password: DEFAULT_PASSWORD },
      { email: "adham.aldini@petromin.com", password: DEFAULT_PASSWORD },
      { email: "sara.belal@qparts.co", password: DEFAULT_PASSWORD },
      { email: "razaz@qparts.co", password: DEFAULT_PASSWORD },
      { email: "o.ghonem@petromin.com", password: DEFAULT_PASSWORD },
      { email: "pac-aboor@petromin.com", password: DEFAULT_PASSWORD },
      { email: "abdulrahman@qparts.co", password: DEFAULT_PASSWORD },
      { email: "alaa@universalcar-sa.com", password: DEFAULT_PASSWORD },
      { email: "pac-darb@petromin.com", password: DEFAULT_PASSWORD },
      { email: "pd@alkhadrltd.com", password: DEFAULT_PASSWORD },
      { email: "pm@alkhadrltd.com", password: DEFAULT_PASSWORD },
      { email: "eslam@qparts.co", password: DEFAULT_PASSWORD },
      { email: "wael.ali@petromin.com", password: DEFAULT_PASSWORD },
      { email: "k.alomiry@universalcar-sa.com", password: DEFAULT_PASSWORD },
      { email: "m.alnasser@petromin.com", password: DEFAULT_PASSWORD },
      { email: "azza@qparts.co", password: DEFAULT_PASSWORD },
      { email: "m.elafany@petromin.com", password: DEFAULT_PASSWORD },
      { email: "ehab@qparts.co", password: DEFAULT_PASSWORD },
      { email: "ws.pur@mulhimauto.com", password: DEFAULT_PASSWORD },
      { email: "ahmed.abdullah@qparts.co", password: DEFAULT_PASSWORD },
      { email: "bilal.sheikh@petromin.com", password: DEFAULT_PASSWORD },
      { email: "m.alkasslab@petromin.com", password: DEFAULT_PASSWORD },
      { email: "atif.awan@petromin.com", password: DEFAULT_PASSWORD },
      { email: "majid.bashir@petromin.com", password: DEFAULT_PASSWORD },
      { email: "abdulkareem.aliakbar@petromin.com", password: DEFAULT_PASSWORD },
      { email: "m.najah@petromin.com", password: DEFAULT_PASSWORD },
      { email: "mohammed.kl@taajeer.com", password: DEFAULT_PASSWORD },
      { email: "shohidul.islam@petromin.com", password: DEFAULT_PASSWORD },
      { email: "m.aslam@petromin.com", password: DEFAULT_PASSWORD },
      { email: "sales@smartoneauto.com", password: DEFAULT_PASSWORD },
      { email: "ahmedaha@saptco.com.sa", password: DEFAULT_PASSWORD },
      { email: "alsaeefat@saptco.com.sa", password: DEFAULT_PASSWORD },
      { email: "alsheikhmh@saptco.com.sa", password: DEFAULT_PASSWORD },
      { email: "alsenanimn@saptco.com.sa", password: DEFAULT_PASSWORD },
      { email: "jamiasdp@saptco.com.sa", password: DEFAULT_PASSWORD },
      { email: "abdelkarimam@saptco.com.sa", password: DEFAULT_PASSWORD },
      { email: "aldawoodas@saptco.com.sa", password: DEFAULT_PASSWORD },
      { email: "abdouof@saptco.com.sa", password: DEFAULT_PASSWORD },
      { email: "aliua@saptco.com.sa", password: DEFAULT_PASSWORD },
      { email: "banayamanas@saptco.com.sa", password: DEFAULT_PASSWORD },
      { email: "fageeraa@saptco.com.sa", password: DEFAULT_PASSWORD },
      { email: "alaa.khedr@qparts.co", password: DEFAULT_PASSWORD },
      { email: "waleed.abdulghafoor@petromin.com", password: DEFAULT_PASSWORD },
      { email: "mohammed.halmi@petromin.com", password: DEFAULT_PASSWORD },
      { email: "ahmed.sayed@petromin.com", password: DEFAULT_PASSWORD },
      { email: "omar@qparts.co", password: DEFAULT_PASSWORD },
      { email: "malik.azhar@petromin.com", password: DEFAULT_PASSWORD },
      { email: "mahmoud.goudah@petromin.com", password: DEFAULT_PASSWORD },
      { email: "h.alrahil@petromin.com", password: DEFAULT_PASSWORD },
      { email: "jay.galapon@petromin.com", password: DEFAULT_PASSWORD },
      { email: "aminah.alotaibi@petromin.com", password: DEFAULT_PASSWORD },
      { email: "m.raoofuddin@petromin.com", password: DEFAULT_PASSWORD },
      { email: "mohannad@qparts.co", password: DEFAULT_PASSWORD },
      { email: "deepak.j@petromin.com", password: DEFAULT_PASSWORD },
      { email: "eyad.fahad@petromin.com", password: DEFAULT_PASSWORD },
      { email: "mohammed.zahid@petromin.com", password: DEFAULT_PASSWORD },
      { email: "mohammed.khaleel@petromin.com", password: DEFAULT_PASSWORD },
      { email: "arshad.k@petromin.com", password: DEFAULT_PASSWORD },
      { email: "majed.khan@petromin.com", password: DEFAULT_PASSWORD },
      { email: "loay.abbas@petromin.com", password: DEFAULT_PASSWORD },
      { email: "mohamed.bilal@qparts.co", password: DEFAULT_PASSWORD },
      { email: "hassan.tariq@petromin.com", password: DEFAULT_PASSWORD },
      { email: "g.syed@petromin.com", password: DEFAULT_PASSWORD },
      { email: "j.meeran@petromin.com", password: DEFAULT_PASSWORD },
      { email: "a.almarakshi@petromin.com", password: DEFAULT_PASSWORD },
      { email: "nawab.zada@petromin.com", password: DEFAULT_PASSWORD },
      { email: "qparts8@gmail.com", password: DEFAULT_PASSWORD },
      { email: "s.syagha@petromin.com", password: DEFAULT_PASSWORD },
      { email: "m.abdulwaheed@petromin.com", password: DEFAULT_PASSWORD },
      { email: "immam.alam@petromin.com", password: DEFAULT_PASSWORD },
      { email: "m.hindi@petromin.com", password: DEFAULT_PASSWORD },
      { email: "aliao@almajdouie.com", password: DEFAULT_PASSWORD },
      { email: "bassam.sakhnini@petromin.com", password: DEFAULT_PASSWORD },
      { email: "ahmed.mohamed@petromin.com", password: DEFAULT_PASSWORD },
      { email: "zahidi.joiya@petromin.com", password: DEFAULT_PASSWORD },
      { email: "amir@qparts.co", password: DEFAULT_PASSWORD },
      { email: "alaa.khedr196@gmail.com", password: DEFAULT_PASSWORD },
      { email: "kalander.mafaz@petromin.com", password: DEFAULT_PASSWORD },
      { email: "arman.iqbal@petromin.com", password: DEFAULT_PASSWORD },
      { email: "s.alromaih@petromin.com", password: DEFAULT_PASSWORD },
      { email: "mirza.kashan@petromin.com", password: DEFAULT_PASSWORD },
      { email: "jaifer.ali@petromin.com", password: DEFAULT_PASSWORD },
      { email: "zahid.asghar@petromin.com", password: DEFAULT_PASSWORD },
      { email: "a.elbedaly@petromin.com", password: DEFAULT_PASSWORD },
      { email: "ahmed.othman@petromin.com", password: DEFAULT_PASSWORD },
      { email: "atawfik@petromin.com", password: DEFAULT_PASSWORD },
      { email: "majed.sayed@petromin.com", password: DEFAULT_PASSWORD },
      { email: "nsamat2012@hotmail.com", password: DEFAULT_PASSWORD },
      { email: "dreams8cars@gmail.com", password: DEFAULT_PASSWORD },
      { email: "sales.body@universalcar-sa.com", password: DEFAULT_PASSWORD },
      { email: "lalshanqiti@tawuniya.com", password: DEFAULT_PASSWORD },
      { email: "alzain@qparts.co", password: DEFAULT_PASSWORD },
      { email: "mohammed.ghayasuddin@aljomaihauto.com", password: DEFAULT_PASSWORD },
      { email: "mohammed.saad@petromin.com", password: DEFAULT_PASSWORD },
      { email: "f.batayb@petromin.com", password: DEFAULT_PASSWORD },
      { email: "ferasmummar@gmail.com", password: DEFAULT_PASSWORD },
      { email: "mahadeer@autolead.sa", password: DEFAULT_PASSWORD },
      { email: "duaa.anwar@qparts.co", password: DEFAULT_PASSWORD },
      { email: "g.thanigaivel@petromin.com", password: DEFAULT_PASSWORD },
      { email: "ahmed.elazab@qparts.co", password: DEFAULT_PASSWORD },
      { email: "mw-80101-jcs@joil.com.sa", password: DEFAULT_PASSWORD },
      { email: "a.abueidhah@petromin.com", password: DEFAULT_PASSWORD },
      { email: "khalid.babiker@petromin.com", password: DEFAULT_PASSWORD },
      { email: "wael.saeed@petromin.com", password: DEFAULT_PASSWORD },
      { email: "omar.moh@qparts.co", password: DEFAULT_PASSWORD },
      { email: "mina.malak@petromin.com", password: DEFAULT_PASSWORD },
      { email: "ali.akbar@petromin.com", password: DEFAULT_PASSWORD },
      { email: "mohammeds@autolead.sa", password: DEFAULT_PASSWORD },
    ];

    // Deduplicate by email (extra safety)
    const seen = new Set<string>();
    const normalizedUsers = users
      .map((u) => ({ email: u.email.trim().toLowerCase(), password: u.password }))
      .filter((u) => u.email && !seen.has(u.email) && (seen.add(u.email), true));

    // ✅ list existing users ONCE
    const existingEmails = new Set<string>();
    let page = 1;
    const perPage = 1000;

    while (true) {
      const { data, error } = await supabaseAdmin.auth.admin.listUsers({ page, perPage });
      if (error) throw error;

      for (const user of data.users) {
        if (user.email) existingEmails.add(user.email.toLowerCase());
      }

      if (data.users.length < perPage) break;
      page++;
    }

    const created: string[] = [];
    const skipped: string[] = [];
    const failed: { email: string; error: string }[] = [];

    for (const u of normalizedUsers) {
      if (existingEmails.has(u.email)) {
        skipped.push(u.email);
        await sleep(200);
        continue;
      }

      const { data, error } = await supabaseAdmin.auth.admin.createUser({
        email: u.email,
        password: u.password,
        email_confirm: true,
      });

      if (error) {
        failed.push({ email: u.email, error: error.message });
      } else {
        created.push(data.user?.email ?? u.email);
        existingEmails.add(u.email);
      }

      await sleep(200);
    }

    return new Response(
      JSON.stringify({
        ok: true,
        totals: {
          input: normalizedUsers.length,
          created: created.length,
          skipped: skipped.length,
          failed: failed.length,
        },
        created,
        skipped,
        failed,
      }),
      { headers: { "Content-Type": "application/json" } },
    );
  } catch (e) {
    return new Response(
      JSON.stringify({ ok: false, error: String((e as any)?.message ?? e) }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
