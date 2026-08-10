-- QNEW-99 Phase 1 seed: the 20 immediate (delay_hours = 0) status-change rows out of the ticket's
-- 34 seed rows. All resolve trigger_status_id/recipient_role_id by name against list_data, per the
-- modern-migration convention in this repo (never hardcoded ids). All shipped pre-enabled on every
-- channel (channels = browser_push/email/whatsapp) — only browser_push (and webhook, once an admin
-- configures a base URL) actually dispatch today; email/whatsapp are no-ops until their own
-- integration tickets ship.
DO $$
DECLARE
  v_new_rfq integer; v_priced integer; v_confirmed integer; v_processing integer;
  v_out_for_delivery integer; v_delivered integer; v_unavailable integer;
  v_cancellation_request integer; v_canceled integer; v_return_request integer;
  v_invoice_issued integer; v_credit_note_issued integer; v_sent_to_vendor integer;
  v_claim_sent integer; v_account_manager_role integer;
  v_channels text[] := ARRAY['browser_push', 'email', 'whatsapp'];
BEGIN
  SELECT list_data_id INTO v_new_rfq FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'New RFQ';
  SELECT list_data_id INTO v_priced FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Priced';
  SELECT list_data_id INTO v_confirmed FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Confirmed';
  SELECT list_data_id INTO v_processing FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Processing';
  SELECT list_data_id INTO v_out_for_delivery FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Out for Delivery';
  SELECT list_data_id INTO v_delivered FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Delivered';
  SELECT list_data_id INTO v_unavailable FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Unavailable';
  SELECT list_data_id INTO v_cancellation_request FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Cancellation Request';
  SELECT list_data_id INTO v_canceled FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Canceled';
  SELECT list_data_id INTO v_return_request FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Return Request';
  SELECT list_data_id INTO v_invoice_issued FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Invoice Issued';
  SELECT list_data_id INTO v_credit_note_issued FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Credit Note Issued';
  SELECT list_data_id INTO v_sent_to_vendor FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Sent To Vendor';
  SELECT list_data_id INTO v_claim_sent FROM qvm_new_apps.list_data WHERE list_id = 3 AND list_data = 'Claim Sent';

  SELECT ur.list_data_id INTO v_account_manager_role
  FROM qvm_new_apps.list_data ur
  JOIN qvm_new_apps.lists l ON l.list_id = ur.list_id AND l.list_name = 'user_role'
  WHERE ur.list_data = 'Qparts Account Manager';

  IF v_new_rfq IS NULL OR v_priced IS NULL OR v_confirmed IS NULL OR v_processing IS NULL
     OR v_out_for_delivery IS NULL OR v_delivered IS NULL OR v_unavailable IS NULL
     OR v_cancellation_request IS NULL OR v_canceled IS NULL OR v_return_request IS NULL
     OR v_invoice_issued IS NULL OR v_credit_note_issued IS NULL OR v_sent_to_vendor IS NULL
     OR v_claim_sent IS NULL OR v_account_manager_role IS NULL THEN
    RAISE EXCEPTION 'notification_rules_seed: one or more required list_data/role lookups did not resolve';
  END IF;

  -- To Client / Workshop
  INSERT INTO qvm_new_apps.notification_rules (trigger_type, trigger_status_id, recipient_type, message_template, channels)
  VALUES
    ('status_change', v_new_rfq, 'client', 'تم استلام طلب التسعير رقم #{order_id} وجاري تجهيزه، راح نوافيكم بالأسعار قريبًا.', v_channels),
    ('status_change', v_priced, 'client', 'تسعيرة طلبكم # {order_id} جاهزة للمراجعة. اضغط لعرض الأسعار: {link}', v_channels),
    ('status_change', v_confirmed, 'client', 'تم تأكيد طلبكم #{order_id} بنجاح، جاري البدء بالتجهيز.', v_channels),
    ('status_change', v_processing, 'client', 'طلبكم # {order_id} الآن قيد التجهيز.', v_channels),
    ('status_change', v_out_for_delivery, 'client', 'طلبكم #{order_id} خرج للتوصيل الآن.', v_channels),
    ('status_change', v_delivered, 'client', 'تم تسليم طلبكم # {order_id}. الرجاء توقيع سند الاستلام: {link}', v_channels),
    ('status_change', v_unavailable, 'client', 'نأسف، الصنف {part_name} في طلبكم #{order_id} غير متوفر حاليًا، جاري البحث عن بديل.', v_channels),
    ('status_change', v_cancellation_request, 'client', 'تم استلام طلب إلغاء الطلب #{order_id} وجاري المراجعة.', v_channels),
    ('status_change', v_canceled, 'client', 'تم إلغاء طلبكم #{order_id} بنجاح.', v_channels),
    ('status_change', v_return_request, 'client', 'تم استلام طلب إرجاع الطلب #{order_id}.', v_channels),
    ('status_change', v_invoice_issued, 'client', 'تم إصدار فاتورة طلبكم #{order_id}. تحميل الفاتورة: {link}', v_channels),
    ('status_change', v_credit_note_issued, 'client', 'تم إصدار إشعار دائن بخصوص طلبكم #{order_id}.', v_channels);

  -- To Vendor
  INSERT INTO qvm_new_apps.notification_rules (trigger_type, trigger_status_id, recipient_type, message_template, channels)
  VALUES
    ('status_change', v_sent_to_vendor, 'vendor', 'لديك طلب تسعير جديد #{rfq_id} من QVM، الرجاء التسعير قبل {deadline}.', v_channels),
    ('status_change', v_confirmed, 'vendor', 'تم قبول عرضكم لطلب #{rfq_id}، الرجاء البدء بالتجهيز.', v_channels),
    ('status_change', v_processing, 'vendor', 'الرجاء تجهيز الصنف الخاص بطلب #{order_id} للتسليم.', v_channels),
    ('status_change', v_claim_sent, 'vendor', 'تم إرسال مطالبة بخصوص الطلب #{order_id}. التفاصيل: {link}', v_channels);

  -- To Internal Team (Account Manager, record owner)
  INSERT INTO qvm_new_apps.notification_rules (trigger_type, trigger_status_id, recipient_type, recipient_role_id, message_template, channels)
  VALUES
    ('status_change', v_priced, 'internal_role', v_account_manager_role, 'تسعيرة جديدة رجعت من مورّد لطلب #{rfq_id}، بانتظار مراجعتك.', v_channels),
    ('status_change', v_cancellation_request, 'internal_role', v_account_manager_role, 'طلب إلغاء جديد #{order_id} من العميل {client_name} يحتاج مراجعة فورية.', v_channels),
    ('status_change', v_return_request, 'internal_role', v_account_manager_role, 'طلب إرجاع جديد #{order_id} من العميل {client_name} يحتاج مراجعة.', v_channels),
    ('status_change', v_unavailable, 'internal_role', v_account_manager_role, 'الصنف {part_name} بطلب #{order_id} غير متوفر عند المورد، يحتاج بحث عن بديل.', v_channels);
END;
$$;
