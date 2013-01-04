Event = mondelefant.new_class()
Event.table = 'event'

Event:add_reference{
  mode          = 'm1',
  to            = "Issue",
  this_key      = 'issue_id',
  that_key      = 'id',
  ref           = 'issue',
}

Event:add_reference{
  mode          = 'm1',
  to            = "Initiative",
  this_key      = 'initiative_id',
  that_key      = 'id',
  ref           = 'initiative',
}

Event:add_reference{
  mode          = 'm1',
  to            = "Suggestion",
  this_key      = 'suggestion_id',
  that_key      = 'id',
  ref           = 'suggestion',
}

Event:add_reference{
  mode          = 'm1',
  to            = "Member",
  this_key      = 'member_id',
  that_key      = 'id',
  ref           = 'member',
}

function Event.object_get:event_name()
  return ({
    issue_state_changed = _"Issue reached next phase",
    initiative_created_in_new_issue = _"New issue",
    initiative_created_in_existing_issue = _"New initiative",
    initiative_revoked = _"Initiative revoked",
    new_draft_created = _"New initiative draft",
    suggestion_created = _"New suggestion"
  })[self.event]
end
  
function Event.object_get:state_name()
  return ({
    admission = _"New",
    discussion = _"Discussion",
    verification = _"Frozen",
    voting = _"Voting",
    canceled_revoked_before_accepted = _"Cancelled (before accepted due to revocation)",
    canceled_issue_not_accepted = _"Cancelled (issue not accepted)",
    canceled_after_revocation_during_discussion = _"Cancelled (during discussion due to revocation)",
    canceled_after_revocation_during_verification = _"Cancelled (during verification due to revocation)",
    calculation = _"Calculation",
    canceled_no_initiative_admitted = _"Cancelled (no initiative admitted)",
    finished_without_winner = _"Finished (without winner)",
    finished_with_winner = _"Finished (with winner)"
  })[self.state]
end
  
function Event.object:send_notification()
  local members_to_notify = Member:new_selector()
    :join("event_seen_by_member", nil, { "event_seen_by_member.seen_by_member_id = member.id AND (event_seen_by_member.notify_level <= member.notify_level OR strpos(member.admin_comment, ' " .. self.issue.policy.id .. " ') > 0) AND event_seen_by_member.id = ?", self.id } )
    :add_where("member.activated NOTNULL AND member.locked = false AND member.notify_email NOTNULL")
    -- SAFETY FIRST, NEVER send notifications for events more then 3 days in past or future
    :add_where("now() - event_seen_by_member.occurrence BETWEEN '-3 days'::interval AND '3 days'::interval")
    -- do not notify a member about the events caused by the member
    :add_where("event_seen_by_member.member_id ISNULL OR event_seen_by_member.member_id != member.id OR strpos(member.admin_comment, ' " .. self.issue.policy.id .. " ') > 0")
    :exec()

  local members_to_notify_now = Member:new_selector()
    :add_where("member.activated NOTNULL AND member.locked = false AND member.notify_email NOTNULL AND strpos(member.admin_comment, ' " .. self.issue.policy.id .. " ') > 0")
    :exec()
  
  for k,v in pairs(members_to_notify_now) do members_to_notify[k] = v end
    
  print (_("Event #{id} -> #{num} members", { id = self.id, num = #members_to_notify }))

  local url

  function table_count(tt, item)
    local count
    count = 0
    for ii,xx in pairs(tt) do
      if item == xx then count = count + 1 end
    end
    return count
  end

  local members_to_notify_reduced
  members_to_notify_reduced = {}
  for ii,xx in ipairs(members_to_notify) do
    if(table_count(members_to_notify_reduced, xx) == 0) then
      members_to_notify_reduced[#members_to_notify_reduced+1] = xx
    end
  end

  for i, member in ipairs(members_to_notify) do
    local subject
    local body = ""
    
    locale.do_with(
      { lang = member.lang or config.default_lang or 'en' },
      function()
        body = body .. _("[event mail]      Unit: #{name}", { name = self.issue.area.unit.name }) .. "\n"
        body = body .. _("[event mail]      Area: #{name}", { name = self.issue.area.name }) .. "\n"
        body = body .. _("[event mail]     Issue: ##{id}", { id = self.issue_id }) .. "\n\n"
        body = body .. _("[event mail]    Policy: #{policy}", { policy = self.issue.policy.name }) .. "\n\n"
        body = body .. _("[event mail]     Event: #{event}", { event = self.event_name }) .. "\n\n"
        body = body .. _("[event mail]     Phase: #{phase}", { phase = self.state_name })
        if not self.issue.closed and self.issue.state_time_left then
          body = body .. " (" .. _("#{time_left} left", { time_left = self.issue.state_time_left:gsub("%..*", ""):gsub("days", _"days"):gsub("day", _"day") }) .. ")"
        end
        body = body .. "\n\n"

        subject = config.mail_subject_prefix .. " " .. self.event_name

        if self.initiative_id then
          url = request.get_absolute_baseurl() .. "initiative/show/" .. self.initiative_id .. ".html"
        elseif self.suggestion_id then
          url = request.get_absolute_baseurl() .. "suggestion/show/" .. self.suggestion_id .. ".html"
        else
          url = request.get_absolute_baseurl() .. "issue/show/" .. self.issue_id .. ".html"
        end
        
        body = body .. _("[event mail]       URL: #{url}", { url = url }) .. "\n\n"

        if self.initiative_id then
          local initiative = Initiative:by_id(self.initiative_id)
          body = body .. _("i#{id}: #{name}", { id = initiative.id, name = initiative.name }) .. "\n\n"
        else
          local initiative_count = Initiative:new_selector()
            :add_where{ "initiative.issue_id = ?", self.issue_id }
            :count()
          local initiatives = Initiative:new_selector()
            :add_where{ "initiative.issue_id = ?", self.issue_id }
            :add_order_by("initiative.supporter_count DESC")
            :limit(3)
            :exec()
          for i, initiative in ipairs(initiatives) do
            body = body .. _("i#{id}: #{name}", { id = initiative.id, name = initiative.name }) .. "\n"
          end
          if initiative_count - 3 > 0 then
            body = body .. _("and #{count} more initiatives", { count = initiative_count - 3 }) .. "\n"
          end
          body = body .. "\n"
        end
        
        if self.suggestion_id then
          local suggestion = Suggestion:by_id(self.suggestion_id)
          body = body .. _("#{name}\n\n", { name = suggestion.name })
        end

        local success = net.send_mail{
          envelope_from = config.mail_envelope_from,
          from          = config.mail_from,
          reply_to      = config.mail_reply_to,
          to            = member.notify_email,
          subject       = subject,
          content_type  = "text/plain; charset=UTF-8",
          content       = body
        }
    
      end
    )
  end

  local subject
  local body = ""

  locale.do_with(
    { lang = config.default_lang or 'en' },
    function()
      if self.event_name == 'Neues Thema' or self.event_name == 'Neue Initiative' or (self.event_name == 'Thema hat die nächste Phase erreicht' and (self.state_name == 'Diskussion' or self.state_name == 'Eingefroren' or self.state_name == 'Abstimmung' or self.state_name == 'Abgeschlossen (mit Gewinner)' and self.state_name == 'Abgeschlossen (ohne Gewinner)')) then
      body = body .. self.issue.area.unit.name .. ": " .. self.issue.area.name .. "\n" .. self.issue.policy.name .. ": [url=" ..  request.get_absolute_baseurl() .. "issue/show/" .. self.issue_id .. ".html]Thema " .. self.issue_id .. "[/url]\n"
      body = body .. _("[event mail]     Event: #{event}", { event = self.event_name }) .. "\n"
      body = body .. _("[event mail]     Phase: #{phase}", { phase = self.state_name })
      if not self.issue.closed and self.issue.state_time_left then
        body = body .. " (" .. _("#{time_left} left", { time_left = self.issue.state_time_left:gsub("%..*", ""):gsub("days", _"days"):gsub("day", _"day") }) .. ")"
      end
      body = body .. "\n"

      if self.initiative_id then
        subject = _("#{name}", { name = self.initiative.name })
        url = request.get_absolute_baseurl() .. "initiative/show/" .. self.initiative_id .. ".html"
      elseif self.suggestion_id then
        subject = _("#{name}", { name = self.suggestion.name })
        url = request.get_absolute_baseurl() .. "suggestion/show/" .. self.suggestion_id .. ".html"
      else
        subject = _("#{name}", { name = self.issue.policy.name })
        url = request.get_absolute_baseurl() .. "issue/show/" .. self.issue_id .. ".html"
      end

      if self.initiative_id then
        local initiative = Initiative:by_id(self.initiative_id)
        body = body .. "[b] [url=" .. request.get_absolute_baseurl() .. "initiative/show/" .. initiative.id .. ".html]i" .. initiative.id .. ": " .. initiative.name .. "[/url] [/b]\n"
--      else
--        local initiative_count = Initiative:new_selector()
--          :add_where{ "initiative.issue_id = ?", self.issue_id }
--          :count()
--        local initiatives = Initiative:new_selector()
--          :add_where{ "initiative.issue_id = ?", self.issue_id }
--          :add_order_by("initiative.supporter_count DESC")
--          :exec()
--        for i, initiative in ipairs(initiatives) do
--          body = body .. "[b] [url=" .. request.get_absolute_baseurl() .. "initiative/show/" .. initiative.id .. ".html]i" .. initiative.id .. ": " .. initiative.name .. "[/url] [/b]\n"
--        end
      end

      if self.suggestion_id then
        local suggestion = Suggestion:by_id(self.suggestion_id)
        body = body .. "[b] [url=" .. request.get_absolute_baseurl() .. "suggestion/show/" .. suggestion.id .. ".html]" .. suggestion.name .. "[/url] [/b]\n[quote]" .. suggestion:get_content("html") .. "[/quote]"
      elseif self.initiative_id then
        local initiative = Initiative:by_id(self.initiative_id)
        body = body .. "[quote]" .. initiative.current_draft:get_content("html") .. "[/quote]\n"
      end

      local body = "" .. self.issue.area.id .. "\n" .. self.issue_id .. "\n" .. subject .. "\n" .. body
      local file = io.open("/tmp/lqfb_notification.txt", "w")
      file:write(body)
      file:close()

      os.execute("/opt/liquid_feedback_core/lf_forum_post")
    end
    end
  )

end

function Event:send_next_notification()
  
  local notification_sent = NotificationSent:new_selector()
    :optional_object_mode()
    :for_update()
    :exec()
    
  local last_event_id = 0
  if notification_sent then
    last_event_id = notification_sent.event_id
  end
  
  local event = Event:new_selector()
    :add_where{ "event.id > ?", last_event_id }
    :add_order_by("event.id")
    :limit(1)
    :optional_object_mode()
    :exec()

  if event then
    if last_event_id == 0 then
      db:query{ "INSERT INTO notification_sent (event_id) VALUES (?)", event.id }
    else
      db:query{ "UPDATE notification_sent SET event_id = ?", event.id }
    end
    
    event:send_notification()
    
    return true

  end

end

function Event:send_notifications_loop()

  while true do
    local did_work = Event:send_next_notification()
    if not did_work then
      print "Sleeping 60 second"
     os.execute("sleep 60")
    end
  end
  
end
