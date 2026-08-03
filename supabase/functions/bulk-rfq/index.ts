// supabase/functions/insert_bulk_order_with_items.ts
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
serve(async (req)=>{
  const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')).schema('qvm_new_apps');
  const reqBody = await req.json();
  const { p_client_id, p_service_advisor, p_order_type, p_parts, p_insurance_company_id } = reqBody;
  // Get status_id for 'Placed Order'
  const status_id = 15;
  // 🕐 Get current time in KSA
  const ksaNow = new Date(Date.now() + 3 * 60 * 60 * 1000);
  const timeStr = ksaNow.toTimeString().slice(0, 5);
  const dayName = ksaNow.toLocaleDateString('en-US', {
    weekday: 'long'
  });
  // 🚀 Extract region from first part (assumes same region applies)
  const firstPart = p_parts[0];
  const { data: regionData, error: regionErr } = await supabase.from('client_branches').select('region_id').eq('customer_id', firstPart.branch).single();
  if (regionErr || !regionData) {
    return new Response(JSON.stringify({
      error: 'Region not found'
    }), {
      status: 400
    });
  }
  const v_region_id = regionData.region_id;
  // Get prefix and sequence name
  const { data: seqData } = await supabase.from('order_number_sequences').select('prefix, sequence_name').eq('lists_data_id', p_client_id).eq('region_id', v_region_id).single();
  let order_number = 'UNKNOWN';
  if (seqData?.sequence_name) {
    const { data: nextVal } = await supabase.rpc('nextval', {
      seqname: seqData.sequence_name
    });
    order_number = `${seqData.prefix}${nextVal}`;
  }
  // 🔍 Determine default shift from first branch
  const { data: slot } = await supabase.from('account_manager_slots').select('*').eq('customer_id', firstPart.branch).single();
  const shift = timeStr > '21:00' || timeStr < '13:00' ? 'Morning Shift' : timeStr < '17:00' ? 'Common Shift' : 'Night Shift';
  const defaultManagerId = shift === 'Morning Shift' ? slot.morning_shift : shift === 'Common Shift' ? slot.common_shift : slot.night_shift;
  let shiftManagerId = defaultManagerId;
  const { data: tempReplacement } = await supabase.from('account_manager_replacements').select('replacement_manager').eq('original_manager', defaultManagerId).eq('customer_id', firstPart.branch).eq('shift_type', shift).lte('start_date', ksaNow.toISOString().split('T')[0]).gte('end_date', ksaNow.toISOString().split('T')[0]).maybeSingle();
  if (tempReplacement?.replacement_manager) {
    shiftManagerId = tempReplacement.replacement_manager;
  } else {
    const { data: user } = await supabase.from('user_data').select('qparts_user_dayoff').eq('user_id', defaultManagerId).maybeSingle();
    const isDayOff = user?.qparts_user_dayoff?.toLowerCase() === dayName.toLowerCase();
    if (isDayOff) {
      shiftManagerId = shift === 'Morning Shift' ? slot.morning_replacement : shift === 'Common Shift' ? slot.common_replacement : slot.night_replacement;
    }
  }
  // Insert order
  const { data: orderData, error: orderErr } = await supabase.from('quotations').insert([
    {
      order_number,
      service_advisor: p_service_advisor,
      order_type: p_order_type,
      account_manager: shiftManagerId,
      insurance_company_id: p_insurance_company_id ?? null
    }
  ]).select('quotation_id').single();
  if (orderErr || !orderData) {
    return new Response(JSON.stringify({
      error: 'Failed to insert order'
    }), {
      status: 500
    });
  }
  const new_order_id = orderData.quotation_id;
  // 🆕 Insert into quotation_account_managers
  const { error: qamErr } = await supabase.from('quotation_account_managers').insert([
    {
      quotation_id: new_order_id,
      assigned_from: shiftManagerId
    }
  ]);
  if (qamErr) {
    console.error('🛑 Failed to insert into quotation_account_managers:', qamErr);
    return new Response(JSON.stringify({
      error: 'Failed to insert account manager assignment',
      details: qamErr.message
    }), {
      status: 500
    });
  }
  // Insert items
  const itemsToInsert = p_parts.map((i)=>({
      quotation_id: new_order_id,
      part_description: i.part_description,
      part_number: i.part_number,
      quantity: parseInt(i.quantity),
      brand_class: i.brand_class,
      item_status: status_id,
      customer_id: i.branch,
      vin: i.vin,
      main_brand: i.main_brand,
      model: i.model
    }));
  const { data: insertedItems, error: insertErr } = await supabase.from('quotation_items').insert(itemsToInsert).select('quotation_item_id');
  if (insertErr) {
    return new Response(JSON.stringify({
      error: 'Failed to insert items'
    }), {
      status: 500
    });
  }
  // Insert notes per item based on matching index
  const noteInserts = insertedItems.map((item, index)=>{
    const original = p_parts[index];
    const noteText = original.notes?.trim();
    if (!noteText) return null;
    return {
      note_description: noteText,
      user_id: p_service_advisor,
      type_id: item.quotation_item_id,
      note_type: 'quotation_item note'
    };
  }).filter(Boolean);
  if (noteInserts.length > 0) {
    const { error: noteErr } = await supabase.from('notes').insert(noteInserts);
    if (noteErr) {
      console.error('Note insert failed:', noteErr);
    }
  }
  return new Response(JSON.stringify({
    success: true,
    order_id: new_order_id
  }), {
    status: 200
  });
});
