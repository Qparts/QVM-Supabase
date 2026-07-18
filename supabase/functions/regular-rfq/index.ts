// supabase/functions/insert_order_with_items.ts
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
serve(async (req)=>{
  const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')).schema('qvm_new_apps');
  const reqBody = await req.json();
  const { p_client_id, p_branch, p_plate_number, p_vin, p_main_brand, p_model, p_all_items_required, p_delivery_type, p_service_advisor, p_order_type, p_parts } = reqBody;
  // Get region_id for branch
  const { data: regionData, error: regionErr } = await supabase.from('client_branches').select('region_id').eq('customer_id', p_branch).single();
  if (regionErr || !regionData) {
    console.error('❌ Region query error:', regionErr);
    console.log('🟡 Region query data:', regionData);
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
    console.log('🔢 nextVal:', nextVal);
    order_number = `${seqData.prefix}${nextVal}`;
  }
  // Get status_id for 'New RFQ'
  const status_id = 15;
  // 🕐 Get current time in KSA
  const ksaNow = new Date(Date.now() + 3 * 60 * 60 * 1000);
  const timeStr = ksaNow.toTimeString().slice(0, 5);
  const dayName = ksaNow.toLocaleDateString('en-US', {
    weekday: 'long'
  });
  let shift;
  if (timeStr > '21:00' || timeStr < '13:00') {
    shift = 'Morning Shift';
  } else if (timeStr >= '13:00' && timeStr < '17:00') {
    shift = 'Common Shift';
  } else {
    shift = 'Night Shift';
  }
  // 👤 Get default shift manager
  const { data: slot } = await supabase.from('account_manager_slots').select('*').eq('customer_id', p_branch).single();
  if (!slot) {
    return new Response(JSON.stringify({
      error: 'No slot config for this branch'
    }), {
      status: 400
    });
  }
  const defaultManagerId = shift === 'Morning Shift' ? slot.morning_shift : shift === 'Common Shift' ? slot.common_shift : slot.night_shift;
  let shiftManagerId = defaultManagerId;
  // 🔁 Check if there's a temporary replacement
  const { data: tempReplacement } = await supabase.from('account_manager_replacements').select('replacement_manager').eq('original_manager', defaultManagerId).eq('customer_id', p_branch).eq('shift_type', shift).lte('start_date', ksaNow.toISOString().split('T')[0]).gte('end_date', ksaNow.toISOString().split('T')[0]).maybeSingle();
  if (tempReplacement?.replacement_manager) {
    shiftManagerId = tempReplacement.replacement_manager;
  } else {
    // 📅 Check if default manager is off today
    const { data: user } = await supabase.from('user_data').select('qparts_user_dayoff').eq('user_id', defaultManagerId).maybeSingle();
    const isDayOff = user?.qparts_user_dayoff?.toLowerCase() === dayName.toLowerCase();
    if (isDayOff) {
      shiftManagerId = shift === 'Morning Shift' ? slot.morning_replacement : shift === 'Common Shift' ? slot.common_replacement : slot.night_replacement;
    }
  }
  // Insert placed_order
  const { data: orderData, error: orderErr } = await supabase.from('quotations').insert([
    {
      order_number,
      plate_number: p_plate_number,
      delivery_type: p_delivery_type,
      service_advisor: p_service_advisor,
      order_type: p_order_type,
      account_manager: shiftManagerId
    }
  ]).select('quotation_id').single();
  if (orderErr || !orderData) {
    console.error('🛑 Failed to insert order:', orderErr);
    return new Response(JSON.stringify({
      error: 'Failed to insert order',
      details: orderErr?.message || 'Unknown'
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
  // ✅ Insert note only if non-empty
  const noteText = reqBody.note_description?.trim();
  if (noteText && noteText.length > 0) {
    const { error: noteErr } = await supabase.from('notes').insert([
      {
        note_description: noteText,
        user_id: reqBody.p_service_advisor,
        type_id: new_order_id,
        note_type: 'quotation note',
        is_internal: false
      }
    ]);
    if (noteErr) {
      console.error('🛑 Failed to insert note:', noteErr);
      return new Response(JSON.stringify({
        error: 'Failed to insert note',
        details: noteErr.message
      }), {
        status: 500
      });
    }
  } else {
    console.log('📝 No note inserted — empty, missing, or only whitespace');
  }
  // Insert placed_items
  const itemsToInsert = p_parts.map((i)=>({
      quotation_id: new_order_id,
      part_description: i.part_description,
      part_number: i.part_number,
      quantity: parseInt(i.quantity),
      brand_class: p_all_items_required !== 'Mixed (Depending on Item)' ? parseInt(p_all_items_required) : i.brand_class ? parseInt(i.brand_class) : null,
      part_photo: i.photo,
      item_status: status_id,
      customer_id: p_branch,
      vin: p_vin,
      main_brand: p_main_brand,
      model: p_model
    }));
  const { error: insertErr } = await supabase.from('quotation_items').insert(itemsToInsert);
  if (insertErr) {
    return new Response(JSON.stringify({
      error: 'Failed to insert items',
      details: insertErr.message
    }), {
      status: 500
    });
  }
  return new Response(JSON.stringify({
    success: true,
    order_id: new_order_id
  }), {
    status: 200
  });
});
